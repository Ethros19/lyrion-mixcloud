package Plugins::MixcloudDirect::ProtocolHandler;

# mcdirect://<username>/<slug>
#
# Plays a Mixcloud show without yt-dlp: at play time the GraphQL API gives us
# the show's HLS url, we pick a variant (192k or 64k AAC), and this handler
# fetches the MPEG-TS segments itself and hands LMS the ADTS AAC inside them.
# There's no socket: sysread serves a buffer that async segment fetches fill,
# returning EINTR ("try again") while one is in flight. Seeks pick the
# segment holding the target time and drop frames up to it.

use strict;
use utf8;
use base qw(IO::Handle);

use Time::HiRes;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Errno;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::MixcloudDirect::API;
use Plugins::MixcloudDirect::Util qw(parseMasterPlaylist parseMediaPlaylist pickVariant segmentAt tsToAdts adtsSkip trackAt);

my $log   = logger('plugin.mixclouddirect');
my $prefs = preferences('plugin.mixclouddirect');

use constant PREFETCH_BYTES => 600_000;   # ~25 s at 192k: keep about two segments ahead
use constant MAX_RETRIES    => 4;
use constant LOW_BANDWIDTH  => 100_000;   # "low" quality = the 64k variant

sub parseUrl {
	my $url = shift || return;
	return $url =~ m{^mcdirect://([^/]+)/([^/?#]+)} ? ($1, $2) : ();
}

sub isRemote        { 1 }
sub isAudio         { 1 }
sub canDirectStream { 0 }    # players can't speak HLS; we always proxy
sub getFormatForURL { 'aac' }
sub formatOverride  { 'aac' }
sub canSeek         { 1 }
sub isRepeatingStream { 0 }
sub audioScrobblerSource { 'P' }
sub getIcon         { Plugins::MixcloudDirect::Plugin->icon }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack->url;
	my ($user, $slug) = parseUrl($url) or return $errorCb->('PLUGIN_MIXCLOUDDIRECT_NOT_FOUND', $url);

	Plugins::MixcloudDirect::API->getShow($user, $slug, sub {
		my ($show, $error) = @_;
		return $errorCb->($error || 'PLUGIN_MIXCLOUDDIRECT_ERROR', $url) unless $show;
		return $errorCb->('PLUGIN_MIXCLOUDDIRECT_NO_STREAM', $url) unless $show->{hls};

		_variant($show->{hls}, sub {
			my ($variant) = @_;
			return $errorCb->('PLUGIN_MIXCLOUDDIRECT_NO_STREAM', $url) unless $variant;

			Plugins::MixcloudDirect::API->getText($variant->{url}, sub {
				my $segments = parseMediaPlaylist(shift, $variant->{url});
				return $errorCb->('PLUGIN_MIXCLOUDDIRECT_NO_STREAM', $url) unless @$segments;

				my $last = $segments->[-1];
				my $secs = $last->{start} + $last->{duration};
				my $bitrate = $variant->{bandwidth} || 64000;

				main::INFOLOG && $log->info("$user/$slug: " . scalar(@$segments) . " segments, ${secs}s, $bitrate bps");

				$song->pluginData(mixcloud => {
					segments => $segments,
					bitrate  => $bitrate,
				});
				$song->duration($secs);

				Slim::Music::Info::setDuration($url, $secs);
				Slim::Music::Info::setBitrate($url, $bitrate);
				Slim::Music::Info::setContentType($url, 'aac');
				$song->currentTrack->title($show->{title}) if $show->{title} && $song->currentTrack->can('title');

				$song->master->currentPlaylistUpdateTime(Time::HiRes::time());
				Slim::Control::Request::notifyFromArray($song->master, ['newmetadata']);

				$successCb->();
			});
		});
	});
}

# master playlist url -> cb->({ url, bandwidth }) for the preferred quality
sub _variant {
	my ($masterUrl, $cb) = @_;

	Plugins::MixcloudDirect::API->getText($masterUrl, sub {
		my $text = shift || return $cb->();

		# a media playlist served directly (no variants)
		return $cb->({ url => $masterUrl, bandwidth => 0 }) if $text =~ /#EXTINF/;

		my $cap = ($prefs->get('quality') || 'high') eq 'low' ? LOW_BANDWIDTH : undef;
		$cb->(pickVariant(parseMasterPlaylist($text, $masterUrl), $cap));
	});
}

sub new {
	my ($class, $args) = @_;

	my $song = $args->{song};
	my $data = $song->pluginData('mixcloud');
	return unless $data && $data->{segments} && @{ $data->{segments} };

	my $from = ($song->seekdata || {})->{timeOffset} || 0;
	my ($index, $into) = segmentAt($data->{segments}, $from);

	main::INFOLOG && $log->info("Streaming $args->{url} from ${from}s (segment $index + ${into}s)");

	# the elapsed-time clock starts here (frames are trimmed to match)
	$song->startOffset($from);

	my $self = $class->SUPER::new;
	${*$self}{mcd} = {
		url      => $args->{url},
		segments => $data->{segments},
		bitrate  => $data->{bitrate},
		next     => $index,
		skip     => $into,
		buf      => '',
		ts       => {},
		retries  => 0,
	};

	$self->_fetch;
	return $self;
}

sub contentType { 'aac' }

sub bitrate {
	my $self = shift;
	return ref $self ? ${*$self}{mcd}{bitrate} : undef;
}

sub _fetch {
	my $self = shift;
	my $v = ${*$self}{mcd} || return;

	return if $v->{pending} || $v->{closed} || $v->{eof};
	return if length($v->{buf}) >= PREFETCH_BYTES;

	if ($v->{next} >= @{ $v->{segments} }) {
		$v->{eof} = 1;
		return;
	}

	my $segment = $v->{segments}[ $v->{next} ];
	$v->{pending} = 1;

	main::DEBUGLOG && $log->debug("Fetching segment $v->{next}: $segment->{url}");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			return if $v->{closed};
			$v->{pending} = 0;

			my $adts = tsToAdts($http->content, $v->{ts});

			if (!length $adts) {
				return $self->_failed("no audio in segment $v->{next}");
			}

			if ($v->{skip}) {
				($adts, my $skipped) = adtsSkip($adts, $v->{skip});
				main::INFOLOG && $log->info(sprintf('Seek: skipped %.2fs into segment %d', $skipped, $v->{next}));
				$v->{skip} = 0;
			}

			$v->{buf} .= $adts;
			$v->{next}++;
			$v->{retries} = 0;

			$self->_fetch;
		},
		sub {
			my (undef, $error) = @_;
			return if $v->{closed};
			$v->{pending} = 0;
			$self->_failed($error);
		},
		{ timeout => 30, request => Plugins::MixcloudDirect::API->request($segment->{url}) },
	)->get($segment->{url});
}

sub _failed {
	my ($self, $error) = @_;
	my $v = ${*$self}{mcd};

	if (++$v->{retries} > MAX_RETRIES) {
		$log->error("Giving up on $v->{url} at segment $v->{next}: $error");
		$v->{eof} = 1;
		return;
	}

	$log->warn("Segment $v->{next} of $v->{url} failed ($error), retry $v->{retries}");
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $v->{retries}, \&_fetch);
}

sub sysread {
	use bytes;
	my $self = $_[0];
	my $v = ${*$self}{mcd};

	if (length $v->{buf}) {
		$_[1] = substr($v->{buf}, 0, $_[2] || 32768, '');
		$self->_fetch;
		return length $_[1];
	}

	if ($v->{eof} && !$v->{pending}) {
		$_[1] = '';
		return 0;
	}

	$self->_fetch;
	$! = EINTR;
	return undef;
}

sub close {
	my $self = shift;
	my $v = ${*$self}{mcd} || return 1;
	$v->{closed} = 1;
	$v->{buf} = '';
	Slim::Utils::Timers::killTimers($self, \&_fetch);
	return 1;
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my $icon = Plugins::MixcloudDirect::Plugin->icon;
	my ($user, $slug) = parseUrl($url) or return {};

	my $show = Plugins::MixcloudDirect::API->cachedShow($user, $slug);
	return { title => $slug, artist => $user, album => 'Mixcloud', cover => $icon, icon => $icon } unless $show;

	my $song = $client && $client->playingSong;
	my $isCurrent = $song && $song->currentTrack && $song->currentTrack->url eq $url;
	my $data = $isCurrent && $song->pluginData('mixcloud');

	my $meta = {
		title    => $show->{title},
		artist   => $show->{owner},
		album    => 'Mixcloud',
		cover    => $show->{image} || $icon,
		icon     => $icon,
		duration => $show->{duration},
		type     => 'AAC (Mixcloud)',
	};
	$meta->{bitrate} = int($data->{bitrate} / 1000) . 'kbps' if $data && $data->{bitrate};

	return $meta unless $data && $show->{tracks} && @{ $show->{tracks} } && !$client->isStopped;

	# the tracklist has start times: show the track playing now
	my $elapsed = $client->controller->playingSongElapsed || 0;
	my $track = trackAt($show->{tracks}, $elapsed);

	if ($track) {
		$meta->{title}  = $track->{title};
		$meta->{artist} = $track->{artist} if $track->{artist};
		$meta->{album}  = "$show->{title} · $show->{owner}";
	}

	# nudge clients to refresh when the track changes
	my $key = $track ? $track->{start} : -1;
	if (!defined $data->{lastTrack} || $data->{lastTrack} != $key) {
		$data->{lastTrack} = $key;
		Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
	}

	_scheduleTrackChange($client, $url, $show->{tracks}, $elapsed);

	return $meta;
}

# Clients that only listen for pushed updates (Material) never ask for
# metadata again by themselves, so wake them when the next track starts.
# Capped so pauses and seeks get re-checked.
use constant MAX_TRACK_WAIT => 60;

sub _scheduleTrackChange {
	my ($client, $url, $tracks, $elapsed) = @_;

	Slim::Utils::Timers::killTimers($client, \&_trackChanged);

	my ($next) = grep { $_->{start} > $elapsed } @$tracks;
	return unless $next;

	my $wait = $next->{start} - $elapsed;
	$wait = MAX_TRACK_WAIT if $wait > MAX_TRACK_WAIT;

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $wait + 0.5, \&_trackChanged, $url);
}

sub _trackChanged {
	my ($client, $url) = @_;

	my $song = $client->playingSong;
	return unless $song && $song->currentTrack && $song->currentTrack->url eq $url;

	# getMetadataFor (run by the status query this triggers) reschedules
	if ($client->isPlaying) {
		__PACKAGE__->getMetadataFor($client, $url);
	}
	else {
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + MAX_TRACK_WAIT, \&_trackChanged, $url);
	}
}

1;
