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

	$prefs->init({ username => '', quality => 'high', showExclusive => 0, follows => {} });

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

# Menu icons: Material Skin sees "MTL_icon_<name>" and draws its own
# (themed) icon of that name; other skins show the PNG (scripts/icon.py).
# Distinct icons also matter in Material: it hides a list's images when
# they're all the same, and never shows an icon on a search field.
sub _icon { 'plugins/MixcloudDirect/html/images/MTL_icon_' . $_[0] . '.png' }

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
				image => _icon('account_circle'),
			}
			: {
				name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SET_USERNAME'),
				type  => 'search',
				url   => \&setUsername,
				image => _icon('account_circle'),
			}
		),
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_FOLLOWED_MENU'),
			type  => 'link',
			url   => \&followedMenu,
			image => _icon('star'),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH'),
			type  => 'link',
			url   => \&searchMenu,
			image => _icon('search'),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_MUSIC_CATEGORIES'),
			type  => 'link',
			url   => \&categories,
			passthrough => [{ format => 'music' }],
			image => _icon('library_music'),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_TALK_CATEGORIES'),
			type  => 'link',
			url   => \&categories,
			passthrough => [{ format => 'talk' }],
			image => _icon('mic'),
		},
	] });
}

sub searchMenu {
	my ($client, $cb) = @_;

	$cb->({ items => [
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH_SHOWS'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'cloudcast' }],
			image => _icon('search'),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH_USERS'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'user' }],
			image => _icon('search'),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_SEARCH_TAGS'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'tag' }],
			image => _icon('search'),
		},
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_OPEN_URL'),
			type  => 'search',
			url   => \&openUrl,
			image => _icon('link'),
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
				image => _icon('more_horiz'),
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
	my $image = pictureUrl($raw->{pictures});

	return {
		name  => $raw->{name} || $user,
		line2 => $raw->{name} && $raw->{name} ne $user ? $user : undef,
		type  => 'link',
		url   => \&userMenu,
		passthrough => [{ user => $user, name => $raw->{name}, image => $image }],
		image => $image || icon(),
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
			image => _icon('queue_music'),
			url  => \&showList,
			passthrough => [{ path => "/$u/cloudcasts/" }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_FAVORITES'),
			type => 'link',
			image => _icon('favorite'),
			url  => \&showList,
			passthrough => [{ path => "/$u/favorites/", ttl => 120 }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_PLAYLISTS'),
			type => 'link',
			image => _icon('playlist_play'),
			url  => \&playlists,
			passthrough => [{ user => $user }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_FOLLOWING'),
			type => 'link',
			image => _icon('people'),
			url  => \&userList,
			passthrough => [{ path => "/$u/following/" }],
		},
	);

	if ($pass->{mine}) {
		splice @items, 2, 0, {
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_LISTENS'),
			type => 'link',
			image => _icon('history'),
			url  => \&showList,
			passthrough => [{ path => "/$u/listens/", ttl => 60 }],
		};
	}
	else {
		# LMS addresses menu entries by position and rebuilds this page on
		# every request, while Material shows its old copy when you go back.
		# So "Follow" sits first and "Unfollow" last: a tap on a stale entry
		# lands on Shows or Following, never on the opposite action.
		my $following = _follows()->{$user};
		my $entry = {
			name => cstring($client, $following ? 'PLUGIN_MIXCLOUDDIRECT_UNFOLLOW' : 'PLUGIN_MIXCLOUDDIRECT_FOLLOW'),
			type => 'link',
			image => _icon($following ? 'person_remove' : 'person_add'),
			url  => \&setFollow,
			passthrough => [{ user => $user, name => $pass->{name}, image => $pass->{image}, follow => !$following }],
			# controllers that honour it redraw this page afterwards
			nextWindow => 'refresh',
		};
		$following ? push(@items, $entry) : unshift(@items, $entry);
	}

	$cb->({ items => \@items });
}

# -- follows (kept in Lyrion, not on Mixcloud) -----------------------------

sub _follows { $prefs->get('follows') || {} }

# Explicit follow/unfollow (see userMenu for why the entry moves)
sub setFollow {
	my ($client, $cb, $args, $pass) = @_;

	my %follows = %{ _follows() };
	my $user = $pass->{user};
	my $name = $pass->{name} || ($follows{$user} && $follows{$user}{name}) || $user;

	if ($pass->{follow}) {
		$follows{$user} ||= { name => $name, image => $pass->{image}, added => time() };
	}
	else {
		delete $follows{$user};
	}

	$prefs->set(follows => \%follows);
	main::INFOLOG && $log->info(($pass->{follow} ? 'follow' : 'unfollow') . ": $user");

	my $token = $pass->{follow} ? 'PLUGIN_MIXCLOUDDIRECT_FOLLOWED' : 'PLUGIN_MIXCLOUDDIRECT_UNFOLLOWED';
	$cb->({ items => [{ name => sprintf(cstring($client, $token), $name), type => 'text' }] });
}

sub followedMenu {
	my ($client, $cb) = @_;

	my $follows = _follows();
	my @users = sort { lc($follows->{$a}{name} || $a) cmp lc($follows->{$b}{name} || $b) } keys %$follows;

	return $cb->({ items => [{ name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_NO_FOLLOWS'), type => 'text' }] }) unless @users;

	$cb->({ items => [
		{
			name  => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_NEW_FROM_FOLLOWED'),
			type  => 'link',
			url   => \&followedFeed,
			image => _icon('new_releases'),
		},
		map {
			my $f = $follows->{$_};
			{
				name  => $f->{name} || $_,
				line2 => $f->{name} && $f->{name} ne $_ ? $_ : undef,
				type  => 'link',
				url   => \&userMenu,
				passthrough => [{ user => $_, name => $f->{name}, image => $f->{image} }],
				image => $f->{image} || icon(),
			}
		} @users
	] });
}

use constant FEED_PER_USER => 10;
use constant FEED_MAX      => 100;

# Latest uploads from everyone followed, newest first
sub followedFeed {
	my ($client, $cb) = @_;

	my @users = keys %{ _follows() };
	return _empty($client, $cb) unless @users;

	my $pending = @users;
	my @shows;

	for my $user (@users) {
		Plugins::MixcloudDirect::API->get('/' . uri_escape_utf8($user) . '/cloudcasts/?limit=' . FEED_PER_USER, sub {
			my $data = shift;
			push @shows, grep { $_ } map { Plugins::MixcloudDirect::API->normalize($_) } @{ $data && $data->{data} || [] };
			return if --$pending;

			my $showExclusive = $prefs->get('showExclusive');
			my @items = map  { _showItem($client, $_) }
			            sort { ($b->{created} || '') cmp ($a->{created} || '') }
			            grep { $showExclusive || !$_->{exclusive} } @shows;
			splice @items, FEED_MAX if @items > FEED_MAX;

			return _empty($client, $cb) unless @items;
			$cb->({ items => \@items });
		}, 900);
	}
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
				image => _icon('more_horiz'),
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
			image => _icon('trending_up'),
			url  => \&showList,
			passthrough => [{ path => "/discover/$slug/popular/", ttl => 1800 }],
		},
		{
			name => cstring($client, 'PLUGIN_MIXCLOUDDIRECT_LATEST'),
			type => 'link',
			image => _icon('new_releases'),
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
			userMenu($client, $cb, $args, { user => $data->{username}, name => $data->{name}, image => pictureUrl($data->{pictures}) });
		});
	}

	_error($client, $cb, 'PLUGIN_MIXCLOUDDIRECT_NOT_FOUND');
}

1;
