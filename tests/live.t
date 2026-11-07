use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;

use Plugins::MixcloudDirect::Util qw(
	parseLiveKey liveUrl parseKey audioRendition parseLivePlaylist
	mp4AudioConfig fmp4Samples adtsHeader fmp4ToAdts adtsInfo
);

sub fixture {
	my $file = "$FindBin::Bin/fixtures/" . shift;
	open my $fh, '<:raw', $file or die "$file: $!";
	local $/;
	return scalar <$fh>;
}

# links
is(parseLiveKey('https://www.mixcloud.com/live/HSEFM/?utm_medium=share&utm_source=clipboard'), 'HSEFM', 'live share link');
is(parseLiveKey('/live/HSEFM'), 'HSEFM', 'live key');
is(parseLiveKey('https://www.mixcloud.com/HSEFM/some-show/'), undef, 'show link is not live');
is(liveUrl('HSEFM'), 'mcdirect://live/HSEFM', 'liveUrl');
is_deeply([ parseKey('https://www.mixcloud.com/live/HSEFM/') ], [], 'live link is not a show');

# master: video variants plus an audio-only rendition
my $master = fixture('live-master.m3u8');
like(audioRendition($master, 'https://live.mixcloud.com/hls/x/y/master.m3u8'),
	qr{^https://live\.mixcloud\.com/hls/x/y/index-audio\.m3u8$}, 'audio rendition, made absolute');
is(audioRendition(fixture('master.m3u8')), undef, 'VOD master has no separate audio rendition');

# live media playlist
my $pl = parseLivePlaylist(fixture('live-audio.m3u8'), 'https://live.mixcloud.com/hls/x/y/index-audio.m3u8');
ok(@{ $pl->{segments} } >= 10, scalar(@{ $pl->{segments} }) . ' segments');
is($pl->{target}, 2, 'target duration');
ok(!$pl->{ended}, 'not ended');
like($pl->{map}, qr{^https://live\.mixcloud\.com/hls/x/y/init-\d+-audio\.mp4$}, 'init segment url');
is($pl->{segments}[0]{seq}, $pl->{sequence}, 'first seq = media sequence');
is($pl->{segments}[1]{seq}, $pl->{sequence} + 1, 'seqs increase');
ok($pl->{sequence} > 1e15, 'big sequence numbers survive');
like($pl->{segments}[-1]{url}, qr{index-audio\d+\.m4s$}, 'segment url');

# init segment: AAC-LC 48 kHz stereo
my $config = mp4AudioConfig(fixture('live-init.mp4'));
ok($config, 'audio config found');
is($config->{object}, 2, 'AAC LC');
is($config->{samplerate}, 48000, '48 kHz');
is($config->{channels}, 2, 'stereo');
is($config->{timescale}, 48000, 'timescale');
is($config->{bitrate}, 320000, 'avgBitrate 320 kbps');

# media segment: 93 frames of 1024 samples (= the 2.005 s EXTINF)
my $segment = fixture('live-segment.m4s');
my @frames = fmp4Samples($segment);
is(scalar @frames, 93, '93 AAC frames');
is(length $frames[0], 853, 'first frame size from trun');

my $hdr = adtsHeader($config, 853);
is(length $hdr, 7, 'ADTS header is 7 bytes');
my $info = adtsInfo($hdr . $frames[0], 0);
is($info->{length}, 860, 'header encodes frame length');
is($info->{samplerate}, 48000, 'header encodes rate');
is($info->{channels}, 2, 'header encodes channels');

my $adts = fmp4ToAdts($segment, $config);
my ($pos, $n) = (0, 0);
while (my $f = adtsInfo($adts, $pos)) { $pos += $f->{length}; $n++ }
is($n, 93, 'ADTS stream: 93 chained frames');
is($pos, length $adts, 'no trailing bytes');
my $kbps = (length($adts) - 93 * 7) * 8 / (93 * 1024 / 48000) / 1000;
ok($kbps > 280 && $kbps < 360, sprintf('about 320 kbps (%.0f)', $kbps));

is(scalar fmp4Samples(''), 0, 'empty segment');
is(mp4AudioConfig('garbage'), undef, 'garbage init');

done_testing;
