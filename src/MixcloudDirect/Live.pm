package Plugins::MixcloudDirect::Live;

# Stream handler for mcdirect://live/<user> (created by ProtocolHandler::new).
#
# Mixcloud Live is an HLS stream with video variants and a separate audio-only
# rendition: AAC (320 kbps seen) in 2-second fragmented-MP4 segments, on a
# sliding-window playlist. We start a few segments behind the live edge, keep
# re-reading the playlist, and hand LMS each new segment's AAC frames wrapped
# in ADTS headers. Like ProtocolHandler there's no socket: sysread serves a
# buffer the async fetches fill, returning EINTR while it's empty.
#
# The stream url carries an access token that expires (about a day); when the
# playlist stops answering we look the stream up again for a fresh one.

use strict;
use utf8;
use base qw(IO::Handle);

use Time::HiRes;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Errno;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::MixcloudDirect::API;
use Plugins::MixcloudDirect::Util qw(audioRendition parseLivePlaylist mp4AudioConfig fmp4ToAdts);

my $log = logger('plugin.mixclouddirect');

use constant BACKLOG        => 3;         # start this many segments behind the live edge
use constant MAX_BUFFER     => 1_000_000; # ~25 s at 320k: don't run further ahead than this
use constant PLAYLIST_FAILS => 3;         # consecutive playlist failures before re-resolving
use constant RESOLVE_FAILS  => 3;         # ... and failed re-resolves before giving up

# user -> { mediaUrl, config }, for getNextTrack (and again after a token expires)
sub resolve {
	my ($class, $user, $cb) = @_;

	Plugins::MixcloudDirect::API->getLive($user, sub {
		my $live = shift;
		return $cb->(undef, 'PLUGIN_MIXCLOUDDIRECT_NOT_FOUND') unless $live;
		return $cb->(undef, 'PLUGIN_MIXCLOUDDIRECT_NOT_LIVE') unless $live->{live};

		Plugins::MixcloudDirect::API->getText($live->{hls}, sub {
			my $mediaUrl = audioRendition(shift, $live->{hls});
			return $cb->(undef, 'PLUGIN_MIXCLOUDDIRECT_NO_STREAM') unless $mediaUrl;

			Plugins::MixcloudDirect::API->getText($mediaUrl, sub {
				my $playlist = parseLivePlaylist(shift, $mediaUrl);
				return $cb->(undef, 'PLUGIN_MIXCLOUDDIRECT_NO_STREAM') unless $playlist->{map} && @{ $playlist->{segments} };

				Plugins::MixcloudDirect::API->getText($playlist->{map}, sub {
					my $config = mp4AudioConfig(shift);
					return $cb->(undef, 'PLUGIN_MIXCLOUDDIRECT_NO_STREAM') unless $config;

					main::INFOLOG && $log->info("live/$user: $mediaUrl, $config->{samplerate} Hz, " . ($config->{bitrate} || '?') . ' bps');
					$cb->({ live => $live, mediaUrl => $mediaUrl, map => $playlist->{map}, config => $config });
				});
			});
		});
	});
}

sub new {
	my ($class, $args) = @_;

	my $data = $args->{song}->pluginData('mixcloud') || {};
	return unless $data->{live} && $data->{mediaUrl} && $data->{config};

	my $self = $class->SUPER::new;
	${*$self}{mcl} = {
		url      => $args->{url},
		user     => $data->{user},
		mediaUrl => $data->{mediaUrl},
		map      => $data->{map},
		config   => $data->{config},
		bitrate  => $data->{bitrate},
		buf      => '',
		queue    => [],
		fails    => 0,
		resolves => 0,
	};

	main::INFOLOG && $log->info("Streaming $args->{url} live");
	$self->_refresh;
	return $self;
}

sub contentType { 'aac' }

sub bitrate {
	my $self = shift;
	return ref $self ? ${*$self}{mcl}{bitrate} : undef;
}

sub _later {
	my ($self, $secs, $method) = @_;
	Slim::Utils::Timers::killTimers($self, $method);
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $secs, $method);
}

# Re-read the playlist, queue new segments, and come back in a target duration
sub _refresh {
	my $self = shift;
	my $v = ${*$self}{mcl} || return;
	return if $v->{closed} || $v->{ended} || $v->{loading};

	$v->{loading} = 1;

	Plugins::MixcloudDirect::API->getText($v->{mediaUrl}, sub {
		my $text = shift;
		return if $v->{closed};
		$v->{loading} = 0;

		my $playlist = defined $text && parseLivePlaylist($text, $v->{mediaUrl});
		my @segments = $playlist ? @{ $playlist->{segments} } : ();

		if (!@segments) {
			return $self->_playlistFailed;
		}
		$v->{fails} = 0;

		if ($playlist->{map} && $playlist->{map} ne ($v->{map} || '')) {
			# new init segment (stream restarted): re-read the audio config first
			return $self->_reinit($playlist->{map});
		}

		if (!defined $v->{next}) {
			my $start = $#segments - BACKLOG + 1;
			$v->{next} = $segments[ $start < 0 ? 0 : $start ]{seq};
		}
		elsif ($v->{next} < $segments[0]{seq}) {
			$log->warn("live/$v->{user}: fell behind, skipping " . ($segments[0]{seq} - $v->{next}) . ' segment(s)');
			$v->{next} = $segments[0]{seq};
		}

		my $queued = @{ $v->{queue} } ? $v->{queue}[-1]{seq} : $v->{next} - 1;
		push @{ $v->{queue} }, grep { $_->{seq} > $queued && $_->{seq} >= $v->{next} } @segments;

		if ($playlist->{ended}) {
			main::INFOLOG && $log->info("live/$v->{user}: stream ended");
			$v->{ended} = 1;
		}
		else {
			$self->_later($playlist->{target} || 2, \&_refresh);
		}

		$self->_fetch;
	});
}

sub _playlistFailed {
	my $self = shift;
	my $v = ${*$self}{mcl};

	if (++$v->{fails} < PLAYLIST_FAILS) {
		return $self->_later(2, \&_refresh);
	}

	# probably an expired token: look the stream up again
	main::INFOLOG && $log->info("live/$v->{user}: playlist unavailable, looking the stream up again");
	$v->{loading} = 1;

	__PACKAGE__->resolve($v->{user}, sub {
		my ($stream, $error) = @_;
		return if $v->{closed};
		$v->{loading} = 0;

		if ($stream) {
			@$v{qw(mediaUrl map config fails resolves)} = (@$stream{qw(mediaUrl map config)}, 0, 0);
			return $self->_refresh;
		}

		my $notLive = ($error || '') eq 'PLUGIN_MIXCLOUDDIRECT_NOT_LIVE';
		if ($notLive || ++$v->{resolves} >= RESOLVE_FAILS) {
			$log->warn("live/$v->{user}: " . ($notLive ? 'no longer live' : 'giving up'));
			$v->{ended} = 1;
			return;
		}
		$self->_later(5, \&_refresh);
	});
}

sub _reinit {
	my ($self, $map) = @_;
	my $v = ${*$self}{mcl};
	$v->{loading} = 1;

	Plugins::MixcloudDirect::API->getText($map, sub {
		my $config = mp4AudioConfig(shift);
		return if $v->{closed};
		$v->{loading} = 0;
		if ($config) {
			@$v{qw(map config)} = ($map, $config);
			main::INFOLOG && $log->info("live/$v->{user}: new init segment");
		}
		$self->_later($config ? 0.1 : 2, \&_refresh);
	});
}

sub _fetch {
	my $self = shift;
	my $v = ${*$self}{mcl} || return;
	return if $v->{closed} || $v->{fetching} || !@{ $v->{queue} } || length($v->{buf}) >= MAX_BUFFER;

	my $segment = shift @{ $v->{queue} };
	$v->{fetching} = 1;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			return if $v->{closed};
			$v->{fetching} = 0;

			my $adts = fmp4ToAdts($http->content, $v->{config});
			$log->warn("live/$v->{user}: no audio in segment $segment->{seq}") unless length $adts;

			$v->{buf} .= $adts;
			$v->{next} = $segment->{seq} + 1;
			$self->_fetch;
		},
		sub {
			my (undef, $error) = @_;
			return if $v->{closed};
			$v->{fetching} = 0;
			# live: don't stall on one segment, move on to the next
			$log->warn("live/$v->{user}: segment $segment->{seq} failed ($error), skipping");
			$v->{next} = $segment->{seq} + 1;
			$self->_fetch;
		},
		{ timeout => 15, request => Plugins::MixcloudDirect::API->request($segment->{url}) },
	)->get($segment->{url});
}

sub sysread {
	use bytes;
	my $self = $_[0];
	my $v = ${*$self}{mcl};

	if (length $v->{buf}) {
		$_[1] = substr($v->{buf}, 0, $_[2] || 32768, '');
		$self->_fetch;
		return length $_[1];
	}

	if ($v->{ended} && !$v->{fetching} && !@{ $v->{queue} }) {
		$_[1] = '';
		return 0;
	}

	$self->_fetch;
	$! = EINTR;
	return undef;
}

sub close {
	my $self = shift;
	my $v = ${*$self}{mcl} || return 1;
	$v->{closed} = 1;
	$v->{buf} = '';
	Slim::Utils::Timers::killTimers($self, \&_refresh);
	return 1;
}

1;
