package Plugins::MixcloudDirect::Plugin;

use strict;
use utf8;
use base qw(Slim::Plugin::OPMLBased);

use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::MixcloudDirect::API;
use Plugins::MixcloudDirect::ProtocolHandler;
use Plugins::MixcloudDirect::Util qw(parseKey cloudcastUrl formatDuration pictureUrl);

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.mixclouddirect',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MIXCLOUDDIRECT',
});

my $prefs = preferences('plugin.mixclouddirect');

use constant PAGE => 50;

sub initPlugin {
	my $class = shift;

	$prefs->init({ username => '', quality => 'high', showExclusive => 0 });

	Slim::Player::ProtocolHandlers->registerHandler(
		mcdirect => 'Plugins::MixcloudDirect::ProtocolHandler'
	);

	if (main::WEBUI) {
		require Plugins::MixcloudDirect::Settings;
		Plugins::MixcloudDirect::Settings->new;
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'mixclouddirect',
		menu   => 'apps',
		is_app => 1,
		weight => 10,
	);
}

sub getDisplayName { 'PLUGIN_MIXCLOUDDIRECT_MENU' }

sub icon { __PACKAGE__->_pluginDataFor('icon') }

sub handleFeed {
	my ($client, $cb) = @_;

	my $username = $prefs->get('username');

	$cb->({ items => [
		($username
			? {
				name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_MY_MIXCLOUD'),
				line2 => $username,
				type  => 'link',
				url   => \&userMenu,
				passthrough => [{ user => $username, mine => 1 }],
				image => icon(),
			}
			: {
				name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SET_USERNAME'),
				type  => 'search',
				url   => \&setUsername,
				image => icon(),
			}
		),
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH_SHOWS'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'cloudcast' }],
			image => icon(),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH_USERS'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'user' }],
			image => icon(),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH_TAGS'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'tag' }],
			image => icon(),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_MUSIC_CATEGORIES'),
			type  => 'link',
			url   => \&categories,
			passthrough => [{ format => 'music' }],
			image => icon(),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_TALK_CATEGORIES'),
			type  => 'link',
			url   => \&categories,
			passthrough => [{ format => 'talk' }],
			image => icon(),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_OPEN_URL'),
			type  => 'search',
			url   => \&openUrl,
			image => icon(),
		},
	] });
}

sub _error {
	my ($client, $cb, $token) = @_;
	$cb->({ items => [{ name => cstring($client, $token || 'PLUGIN_MIXCLOUDDIRECT_ERROR'), type => 'text' }] });
}

sub _empty {
	my ($client, $cb) = @_;
	$cb->({ items => [{ name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_EMPTY'), type => 'text' }] });
}

# -- shows -----------------------------------------------------------------

sub _showItem {
	my ($client, $show) = @_;

	my $title = $show->{title} || $show->{slug};
	my $sub = join(' · ', grep { $_ } $show->{owner}, formatDuration($show->{duration}), substr($show->{created} || '', 0, 10));

	# LyrionJS saves favourites under `name`, so it carries the full title;
	# line1/line2 are what list views show.
	return {
		name  => "$title - $show->{owner}",
		line1 => $title,
		line2 => $sub,
		favorites_title => "$title - $show->{owner}",
		type  => 'audio',
		url   => cloudcastUrl($show->{user}, $show->{slug}),
		play  => cloudcastUrl($show->{user}, $show->{slug}),
		image => $show->{image} || icon(),
		duration => $show->{duration},
		on_select => 'play',
	};
}

# A REST list of cloudcasts at $path -> menu, with "More" for the next page
sub showList {
	my ($client, $cb, $args, $pass) = @_;

	my $path = $pass->{path};
	$path .= ($path =~ /\?/ ? '&' : '?') . 'limit=' . PAGE unless $path =~ /[?&]limit=/;

	Plugins::MixcloudDirect::API->get($path, sub {
		my ($data, $error) = @_;
		return _error($client, $cb, $error ? 'PLUGIN_MIXCLOUDDIRECT_NOT_FOUND' : undef) unless $data && $data->{data};

		my $showExclusive = $prefs->get('showExclusive');
		my @items;
		my $hidden = 0;

		for my $raw (@{ $data->{data} }) {
			# playlists and favourites can hold deleted shows
			my $show = Plugins::MixcloudDirect::API->normalize($raw) || next;
			if ($show->{exclusive} && !$showExclusive) {
				$hidden++;
				next;
			}
			push @items, _showItem($client, $show);
		}

		main::INFOLOG && $hidden && $log->info("$path: hid $hidden exclusive show(s)");

		if (my $next = $data->{paging} && $data->{paging}{next}) {
			push @items, {
				name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_MORE'),
				type => 'link',
				url  => \&showList,
				passthrough => [{ path => $next }],
			} if @{ $data->{data} };
		}

		return _empty($client, $cb) unless @items;
		$cb->({ items => \@items });
	}, $pass->{ttl} || 300);
}

# -- users -----------------------------------------------------------------

sub _userItem {
	my ($client, $raw) = @_;
	my $user = $raw->{username} || return;

	return {
		name  => $raw->{name} || $user,
		line2 => $raw->{name} && $raw->{name} ne $user ? $user : undef,
		type  => 'link',
		url   => \&userMenu,
		passthrough => [{ user => $user }],
		image => pictureUrl($raw->{pictures}) || icon(),
	};
}

sub userMenu {
	my ($client, $cb, $args, $pass) = @_;

	my $user = $pass->{user};
	my $u = uri_escape_utf8($user);

	my @items = (
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_UPLOADS'),
			type => 'link',
			url  => \&showList,
			passthrough => [{ path => "/$u/cloudcasts/" }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_FAVORITES'),
			type => 'link',
			url  => \&showList,
			passthrough => [{ path => "/$u/favorites/", ttl => 120 }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_PLAYLISTS'),
			type => 'link',
			url  => \&playlists,
			passthrough => [{ user => $user }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_FOLLOWING'),
			type => 'link',
			url  => \&userList,
			passthrough => [{ path => "/$u/following/" }],
		},
	);

	if ($pass->{mine}) {
		splice @items, 2, 0, {
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_LISTENS'),
			type => 'link',
			url  => \&showList,
			passthrough => [{ path => "/$u/listens/", ttl => 60 }],
		};
	}

	$cb->({ items => \@items });
}

sub userList {
	my ($client, $cb, $args, $pass) = @_;

	my $path = $pass->{path};
	$path .= ($path =~ /\?/ ? '&' : '?') . 'limit=' . PAGE unless $path =~ /[?&]limit=/;

	Plugins::MixcloudDirect::API->get($path, sub {
		my $data = shift;
		return _error($client, $cb) unless $data && $data->{data};

		my @items = grep { $_ } map { _userItem($client, $_) } @{ $data->{data} };

		if (my $next = $data->{paging} && $data->{paging}{next}) {
			push @items, {
				name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_MORE'),
				type => 'link',
				url  => \&userList,
				passthrough => [{ path => $next }],
			} if @{ $data->{data} };
		}

		return _empty($client, $cb) unless @items;
		$cb->({ items => \@items });
	}, 600);
}

sub playlists {
	my ($client, $cb, $args, $pass) = @_;
	my $u = uri_escape_utf8($pass->{user});

	Plugins::MixcloudDirect::API->get("/$u/playlists/?limit=100", sub {
		my $data = shift;
		return _error($client, $cb) unless $data && $data->{data};

		my @items = map {
			my ($owner, $slug) = parseKey($_->{key});
			$slug ? {
				name => $_->{name} || $slug,
				type => 'link',
				url  => \&showList,
				passthrough => [{ path => "/$owner/playlists/$slug/cloudcasts/" }],
			} : ();
		} @{ $data->{data} };

		return _empty($client, $cb) unless @items;
		$cb->({ items => \@items });
	}, 600);
}

sub setUsername {
	my ($client, $cb, $args) = @_;

	my $input = $args->{search} || '';
	$input =~ s{^\s+|\s+$}{}g;
	$input =~ s{^https?://(?:www\.|m\.)?mixcloud\.com/}{}i;
	$input =~ s{/.*$}{};

	return _error($client, $cb, 'PLUGIN_MIXCLOUDDIRECT_NO_SUCH_USER') unless length $input;

	Plugins::MixcloudDirect::API->get('/' . uri_escape_utf8($input) . '/', sub {
		my $data = shift;
		return _error($client, $cb, 'PLUGIN_MIXCLOUDDIRECT_NO_SUCH_USER') unless $data && $data->{username};

		$prefs->set(username => $data->{username});
		$log->info("Mixcloud username set to $data->{username}");
		userMenu($client, $cb, $args, { user => $data->{username}, mine => 1 });
	});
}

# -- search, categories, links ---------------------------------------------

sub search {
	my ($client, $cb, $args, $pass) = @_;

	my $query = $args->{search};
	my $type = $pass->{type};
	return _empty($client, $cb) unless defined $query && length $query;

	if ($type eq 'cloudcast') {
		return showList($client, $cb, $args, {
			path => '/search/?type=cloudcast&q=' . uri_escape_utf8($query),
			ttl  => 600,
		});
	}

	Plugins::MixcloudDirect::API->search($type, $query, sub {
		my $data = shift;
		return _error($client, $cb) unless $data && $data->{data};

		my @items;
		if ($type eq 'user') {
			@items = grep { $_ } map { _userItem($client, $_) } @{ $data->{data} };
		}
		else {
			@items = map { _tagItem($client, $_) } @{ $data->{data} };
		}

		return _empty($client, $cb) unless @items;
		$cb->({ items => \@items });
	});
}

# A genre/tag ("/genres/house/") or category ("/categories/house/") -> Popular / Latest
sub _tagItem {
	my ($client, $raw) = @_;
	my ($slug) = ($raw->{key} || '') =~ m{^/(?:genres|categories|discover)/([^/]+)/};

	return {
		name => $raw->{name} || $slug,
		type => 'link',
		url  => \&discover,
		passthrough => [{ slug => $slug }],
	};
}

sub discover {
	my ($client, $cb, $args, $pass) = @_;
	my $slug = uri_escape_utf8($pass->{slug});

	$cb->({ items => [
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_POPULAR'),
			type => 'link',
			url  => \&showList,
			passthrough => [{ path => "/discover/$slug/popular/", ttl => 1800 }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_LATEST'),
			type => 'link',
			url  => \&showList,
			passthrough => [{ path => "/discover/$slug/latest/", ttl => 300 }],
		},
	] });
}

sub categories {
	my ($client, $cb, $args, $pass) = @_;

	Plugins::MixcloudDirect::API->get('/categories/', sub {
		my $data = shift;
		return _error($client, $cb) unless $data && $data->{data};

		my @items = map { _tagItem($client, $_) }
		            grep { ($_->{format} || 'music') eq $pass->{format} }
		            @{ $data->{data} };

		return _empty($client, $cb) unless @items;
		$cb->({ items => \@items });
	}, 86400);
}

# Paste a mixcloud.com link: a show plays, a profile opens
sub openUrl {
	my ($client, $cb, $args) = @_;

	my $input = $args->{search} || '';
	$input =~ s{^\s+|\s+$}{}g;

	if (my ($user, $slug) = parseKey($input)) {
		return Plugins::MixcloudDirect::API->getShow($user, $slug, sub {
			my ($show, $error) = @_;
			return _error($client, $cb, $error) unless $show;
			$cb->({ items => [ _showItem($client, { %$show, created => '' }) ] });
		});
	}

	if (my ($user) = $input =~ m{^(?:https?://(?:www\.|m\.)?mixcloud\.com)?/?([^/\s]+)/?}i) {
		return Plugins::MixcloudDirect::API->get('/' . uri_escape_utf8($user) . '/', sub {
			my $data = shift;
			return _error($client, $cb, 'PLUGIN_MIXCLOUDDIRECT_NOT_FOUND') unless $data && $data->{username};
			userMenu($client, $cb, $args, { user => $data->{username} });
		});
	}

	_error($client, $cb, 'PLUGIN_MIXCLOUDDIRECT_NOT_FOUND');
}

1;
