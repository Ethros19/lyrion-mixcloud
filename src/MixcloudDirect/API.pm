package Plugins::MixcloudDirect::API;

# Async client for Mixcloud's two public, unauthenticated APIs:
#  - REST (api.mixcloud.com): browsing, search, a user's uploads/favourites/...
#  - GraphQL (app.mixcloud.com/graphql): per-show stream urls and tracklist
#
# Both are reachable without OAuth, which is what lets this plugin work on
# LMS < 9.2: www.mixcloud.com (where OAuth lives) answers with
# "Content-Encoding: identity", which older LMS mistakes for compression and
# turns into an empty body. These two hosts send none or gzip.

use strict;
use utf8;

use HTTP::Request;
use JSON::XS ();
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::MixcloudDirect::Util qw(decodeStreamUrl parseKey pictureUrl);

use constant REST    => 'https://api.mixcloud.com';
use constant GRAPHQL => 'https://app.mixcloud.com/graphql';

my $log   = logger('plugin.mixclouddirect');
my $cache = Slim::Utils::Cache->new;

# in-memory show details so getMetadataFor never waits on the network
my %shows;

# Mixcloud's hosts answer HTTP/1.0 (LMS's default) with "426 Upgrade
# Required"; passing our own request object is how LMS lets us say 1.1.
# Its CDN also 403s LMS's default User-Agent ("iTunes/4.7.1 ..."), so we
# send our own (LMS only fills in headers that aren't set).
my $userAgent;

sub request {
	my ($class, $url, %headers) = @_;

	$userAgent ||= 'Lyrion Music Server (MixcloudDirect/' . (Plugins::MixcloudDirect::Plugin->_pluginDataFor('version') || '0') . ')';

	my $request = HTTP::Request->new(GET => $url);
	$request->protocol('HTTP/1.1');
	$request->header(Connection => 'close');
	$request->header('User-Agent' => $userAgent);
	$request->header($_ => $headers{$_}) for keys %headers;

	return $request;
}

sub _fetch {
	my ($url, $cb) = @_;

	main::DEBUGLOG && $log->debug("GET $url");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $data = eval { from_json($http->content) };
			if ($@ || !$data) {
				my $ce = $http->headers->header('Content-Encoding') || '';
				$log->error("Bad JSON from $url" . ($ce ? " (Content-Encoding: $ce)" : '') . ": $@");
				return $cb->();
			}
			$cb->($data);
		},
		sub {
			my ($http, $error) = @_;
			# the REST API answers 4xx with a JSON error body
			my $data = $http && $http->can('content') && eval { from_json($http->content) };
			my $detail = $data && $data->{error} ? " ($data->{error}{type}: $data->{error}{message})" : '';
			$log->error("Request failed for $url: $error$detail");
			$cb->(undef, $data && $data->{error});
		},
		{ timeout => 20, request => __PACKAGE__->request($url, Accept => 'application/json') },
	)->get($url);
}

# REST GET; $path may be a full url (paging.next) or "/discover/house/popular/"
sub get {
	my ($class, $path, $cb, $ttl) = @_;

	my $url = $path =~ m{^https?://} ? $path : REST . $path;
	my $key = "mcd:$url";

	if ($ttl && (my $cached = $cache->get($key))) {
		return $cb->($cached);
	}

	_fetch($url, sub {
		my ($data, $error) = @_;
		$cache->set($key, $data, $ttl) if $data && $ttl && !$data->{error};
		$cb->($data, $error);
	});
}

sub search {
	my ($class, $type, $query, $cb) = @_;
	$class->get('/search/?limit=50&type=' . $type . '&q=' . uri_escape_utf8($query), $cb, 600);
}

# REST cloudcast entry -> the shape menus and metadata use
sub normalize {
	my ($class, $raw) = @_;

	my ($user, $slug) = parseKey($raw->{key}) or return;

	my $show = {
		user      => $user,
		slug      => $slug,
		title     => $raw->{name},
		owner     => $raw->{user} && $raw->{user}{name} || $user,
		image     => pictureUrl($raw->{pictures}),
		duration  => $raw->{audio_length},
		exclusive => $raw->{is_exclusive} ? 1 : 0,
		created   => $raw->{created_time},
		tags      => [ map { $_->{name} } @{ $raw->{tags} || [] } ],
	};

	# keep what we know for now-playing; GraphQL fills in the rest at play time
	my $id = "$user/$slug";
	$shows{$id} = { %{ $shows{$id} || {} }, %$show, fetched => $shows{$id} && $shows{$id}{fetched} };

	return $show;
}

sub cachedShow {
	my ($class, $user, $slug) = @_;
	my $id = "$user/$slug";
	return $shows{$id} ||= $cache->get("mcd:show:$id");
}

use constant SHOW_QUERY => <<'EOQ';
{
  cloudcastLookup(lookup: {username: %s, slug: %s}) {
    name
    audioLength
    isExclusive
    restrictedReason
    publishDate
    owner { displayName username }
    picture(width: 800, height: 800) { url }
    streamInfo { url hlsUrl }
    sections {
      __typename
      ... on TrackSection { artistName songName startSeconds }
      ... on ChapterSection { chapter startSeconds }
    }
  }
}
EOQ

# Full details for one show, always fresh (stream urls are short-lived):
# cb->(show) or cb->(undef, reason) where reason is a strings.txt token
sub getShow {
	my ($class, $user, $slug, $cb) = @_;

	my $json = JSON::XS->new->allow_nonref;
	my $query = sprintf(SHOW_QUERY, $json->encode($user), $json->encode($slug));
	my $url = GRAPHQL . '?query=' . uri_escape_utf8($query);

	_fetch($url, sub {
		my $data = shift;
		my $raw = $data && $data->{data} && $data->{data}{cloudcastLookup};

		if (!$raw) {
			my $err = $data && $data->{errors} && $data->{errors}[0]{message};
			$log->warn("No show for $user/$slug" . ($err ? ": $err" : ''));
			return $cb->(undef, $data ? 'PLUGIN_MIXCLOUDDIRECT_NOT_FOUND' : 'PLUGIN_MIXCLOUDDIRECT_ERROR');
		}

		my @sections;
		for my $s (@{ $raw->{sections} || [] }) {
			next unless defined $s->{startSeconds};
			if (($s->{__typename} || '') eq 'TrackSection') {
				push @sections, { start => $s->{startSeconds}, artist => $s->{artistName}, title => $s->{songName} };
			}
			elsif ($s->{chapter}) {
				push @sections, { start => $s->{startSeconds}, title => $s->{chapter} };
			}
		}
		@sections = sort { $a->{start} <=> $b->{start} } @sections;

		my $stream = $raw->{streamInfo} || {};
		my $show = {
			%{ $class->cachedShow($user, $slug) || {} },
			user       => $user,
			slug       => $slug,
			title      => $raw->{name},
			owner      => $raw->{owner} && $raw->{owner}{displayName} || $user,
			image      => $raw->{picture} && $raw->{picture}{url},
			duration   => $raw->{audioLength},
			exclusive  => $raw->{isExclusive} ? 1 : 0,
			restricted => $raw->{restrictedReason},
			tracks     => \@sections,
			fetched    => 1,
		};

		my $id = "$user/$slug";
		$shows{$id} = $show;
		$cache->set("mcd:show:$id", $show, '7 days');

		if (my $reason = $show->{restricted}) {
			$log->warn("$id is restricted: $reason");
			return $cb->(undef, $reason eq 'tracklist'   ? 'PLUGIN_MIXCLOUDDIRECT_GEO_BLOCKED'
			                  : $reason eq 'repeat_play' ? 'PLUGIN_MIXCLOUDDIRECT_REPEAT_PLAY'
			                  :                            'PLUGIN_MIXCLOUDDIRECT_RESTRICTED');
		}

		my $hls = decodeStreamUrl($stream->{hlsUrl});
		my $progressive = decodeStreamUrl($stream->{url});

		if (!$hls && !$progressive) {
			return $cb->(undef, $show->{exclusive} ? 'PLUGIN_MIXCLOUDDIRECT_EXCLUSIVE' : 'PLUGIN_MIXCLOUDDIRECT_NO_STREAM');
		}

		# not cached: these urls expire
		$cb->({ %$show, hls => $hls, progressive => $progressive });
	});
}

use constant LIVE_FIELDS => 'username displayName picture(width: 800, height: 800) { url } isLive liveStream { name description hlsUrl streamStatus }';

my %lives;

sub _normalizeLive {
	my $raw = shift || return;
	my $stream = $raw->{liveStream} || {};
	my $live = {
		user        => $raw->{username},
		owner       => $raw->{displayName} || $raw->{username},
		image       => $raw->{picture} && $raw->{picture}{url},
		live        => ($raw->{isLive} && ($stream->{streamStatus} || 'LIVE') eq 'LIVE' && $stream->{hlsUrl}) ? 1 : 0,
		name        => $stream->{name},
		description => $stream->{description},
	};
	$lives{ lc $live->{user} } = { %$live };       # metadata only: the url expires
	$live->{hls} = $stream->{hlsUrl} if $live->{live};
	return $live;
}

# Is <user> broadcasting? cb->({ user, owner, image, live, name, description, hls })
# or cb->() if there's no such user
sub getLive {
	my ($class, $user, $cb) = @_;

	my $json = JSON::XS->new->allow_nonref;
	my $query = '{ userLookup(lookup: {username: ' . $json->encode($user) . '}) { ' . LIVE_FIELDS . ' } }';

	_fetch(GRAPHQL . '?query=' . uri_escape_utf8($query), sub {
		my $data = shift;
		$cb->(_normalizeLive($data && $data->{data} && $data->{data}{userLookup}));
	});
}

# Several users, ten per request (GraphQL aliases, kept short enough for a
# GET url): cb->({ lc(user) => live })
use constant LIVE_BATCH => 10;

sub getLives {
	my ($class, $users, $cb) = @_;
	my @users = @{ $users || [] };
	return $cb->({}) unless @users;

	my $json = JSON::XS->new->allow_nonref;
	my %out;
	my @batches;
	push @batches, [ splice @users, 0, LIVE_BATCH ] while @users;
	my $pending = @batches;

	for my $batch (@batches) {
		my $i = 0;
		my $query = '{ ' . join(' ', map { 'u' . $i++ . ': userLookup(lookup: {username: ' . $json->encode($_) . '}) { ' . LIVE_FIELDS . ' }' } @$batch) . ' }';

		_fetch(GRAPHQL . '?query=' . uri_escape_utf8($query), sub {
			my $data = shift;
			for my $raw (values %{ $data && $data->{data} || {} }) {
				my $live = _normalizeLive($raw) || next;
				$out{ lc $live->{user} } = $live;
			}
			$cb->(\%out) unless --$pending;
		});
	}
}

sub cachedLive {
	my ($class, $user) = @_;
	return $lives{ lc $user };
}

# Plain-text GET (HLS playlists)
sub getText {
	my ($class, $url, $cb) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub { $cb->(shift->content) },
		sub { $log->error("Request failed for $url: $_[1]"); $cb->() },
		{ timeout => 20, request => $class->request($url) },
	)->get($url);
}

1;
