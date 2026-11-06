package Plugins::MixcloudDirect::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.mixclouddirect');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIXCLOUDDIRECT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MixcloudDirect/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(username quality showExclusive));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		# accept a pasted profile link as well as a bare username
		my $user = $params->{pref_username} // '';
		$user =~ s{^\s+|\s+$}{}g;
		$user =~ s{^https?://(?:www\.|m\.)?mixcloud\.com/}{}i;
		$user =~ s{/.*$}{};
		$params->{pref_username} = $user;
		$params->{pref_showExclusive} ||= 0;
	}

	return $class->SUPER::handler($client, $params, $callback, @args);
}

sub beforeRender {
	my ($class, $params) = @_;
	$params->{mcdVersion} = Plugins::MixcloudDirect::Plugin->_pluginDataFor('version');
}

1;
