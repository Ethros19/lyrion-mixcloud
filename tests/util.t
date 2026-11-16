use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;

use Plugins::MixcloudDirect::Util qw(
	decodeStreamUrl decodePathComponent parseKey cloudcastUrl
	parseMasterPlaylist parseMediaPlaylist pickVariant segmentAt
	tsToAdts adtsInfo adtsSkip
	formatDuration pictureUrl trackAt
);

sub fixture {
	my $file = "$FindBin::Bin/fixtures/" . shift;
	open my $fh, '<:raw', $file or die "$file: $!";
	local $/;
	return scalar <$fh>;
}

# stream url decoding (real GraphQL value)
{
	(my $b64 = fixture('stream_url.b64')) =~ s/\s+//g;
	my $url = decodeStreamUrl($b64);
	like($url, qr{^https://dl\.mixcloud\.com/secure/.+\.m4a\?sig=}, 'decodes streamInfo.url');
	is(decodeStreamUrl(''), undef, 'empty -> undef');
	is(decodeStreamUrl('bm90IGEgdXJs'), undef, 'garbage -> undef');
}

# keys / urls
is_deeply([ parseKey('/dholbach/cryptkeeper/') ], [qw(dholbach cryptkeeper)], 'key');
is_deeply([ parseKey('https://www.mixcloud.com/dholbach/cryptkeeper/?utm=x') ], [qw(dholbach cryptkeeper)], 'web url');
is_deeply([ parseKey('https://m.mixcloud.com/dholbach/cryptkeeper') ], [qw(dholbach cryptkeeper)], 'mobile url, no slash');
is_deeply([ parseKey('/dholbach/') ], [], 'user only');
is_deeply([ parseKey('/dholbach/favorites/') ], [], 'user subpage');
is(cloudcastUrl('a', 'b'), 'mcdirect://a/b', 'cloudcastUrl');

# REST keys and pasted links stay encoded until the GraphQL lookup boundary.
{
	my @slugs = (
		[
			'10426-cello-octets-from-arvo-p%C3%A4rt-saariaho-beving-villa-lobos-rachmaninoff-more',
			"10426-cello-octets-from-arvo-p\x{e4}rt-saariaho-beving-villa-lobos-rachmaninoff-more",
		],
		[
			'82326-france-pt-8-w-luc-ferrari-alain-bancquart-g%C3%A9rard-grisey-micha%C3%ABl-levinas-more',
			"82326-france-pt-8-w-luc-ferrari-alain-bancquart-g\x{e9}rard-grisey-micha\x{eb}l-levinas-more",
		],
	);
	for my $case (@slugs) {
		my ($encoded, $unicode) = @$case;
		my ($user, $slug) = parseKey("/deafmix3/$encoded/");
		is(decodePathComponent($slug), $unicode, 'REST slug decoded for lookup');
		is(cloudcastUrl($user, $slug), "mcdirect://deafmix3/$encoded", 'playback URL retains encoded slug');
		my (undef, $pasted) = parseKey("https://www.mixcloud.com/deafmix3/$encoded/?utm=x");
		is(decodePathComponent($pasted), $unicode, 'pasted show link decoded for lookup');
		is(decodePathComponent($unicode), $unicode, 'raw Unicode slug preserved');
	}
	is(decodePathComponent('cryptkeeper'), 'cryptkeeper', 'ASCII slug unchanged');
	is(decodePathComponent("p\x{e4}rt-g%c3%a9rard"), "p\x{e4}rt-g\x{e9}rard", 'mixed Unicode and lowercase escapes');
	is(decodePathComponent('show+100%25%20%26%2F%3F%23'), 'show+100% &/?#', 'path escaping is not form decoding');
	is(decodePathComponent('literal-%25C3%25A4'), 'literal-%C3%A4', 'percent escapes decoded only once');
	is(decodePathComponent('100%-live%zz'), '100%-live%zz', 'literal percent signs preserved');
	eval { decodePathComponent('%FF') };
	like($@, qr/UTF-8/, 'invalid UTF-8 rejected rather than silently replaced');
}

# HLS
{
	my $variants = parseMasterPlaylist(fixture('master.m3u8'));
	is(scalar @$variants, 2, 'two variants');
	is($variants->[0]{bandwidth}, 192001, 'best first');
	like($variants->[0]{url}, qr{-192K\.m4a/streamindex-a1\.m3u8$}, 'variant url');
	is(pickVariant($variants)->{bandwidth}, 192001, 'pick best');
	is(pickVariant($variants, 100_000)->{bandwidth}, 64003, 'pick under cap');
	is(pickVariant($variants, 1000)->{bandwidth}, 64003, 'nothing fits -> lowest');

	my $rel = parseMasterPlaylist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow/index.m3u8\n", 'https://h.example/a/master.m3u8?x=1');
	is($rel->[0]{url}, 'https://h.example/a/low/index.m3u8', 'relative variant');

	my $segs = parseMediaPlaylist(fixture('media.m3u8'));
	ok(@$segs >= 5, 'segments parsed');
	like($segs->[0]{url}, qr{/seg-1-a1\.ts$}, 'segment url');
	is($segs->[0]{start}, 0, 'first starts at 0');
	is($segs->[1]{start}, 10.008, 'second starts after first');

	is_deeply([ segmentAt($segs, 0) ], [0, 0], 'segmentAt 0');
	my ($i, $into) = segmentAt($segs, 25);
	is($i, 2, 'segmentAt 25s -> third');
	ok(abs($into - (25 - 20.016)) < 1e-6, 'offset into segment');
	is((segmentAt($segs, 1e6))[0], scalar @$segs, 'past end');
}

# TS -> ADTS (real segment head)
{
	my $state = {};
	my $adts = tsToAdts(fixture('segment.ts'), $state);
	ok(length $adts > 10_000, 'audio extracted: ' . length $adts);
	ok(defined $state->{pid}, "audio pid $state->{pid}");

	my $frame = adtsInfo($adts, 0);
	ok($frame, 'starts on an ADTS frame');
	is($frame->{samplerate}, 44100, '44.1 kHz');
	is($frame->{channels}, 2, 'stereo');

	# frames chain back to back
	my ($pos, $n) = (0, 0);
	while (my $f = adtsInfo($adts, $pos)) { $pos += $f->{length}; $n++ }
	ok($n > 20, "$n consecutive frames");
	ok(length($adts) - $pos < 2048, 'only a partial frame left over');

	my ($rest, $skipped) = adtsSkip($adts, 0.5);
	ok($skipped >= 0.5 && $skipped < 0.53, "skipped ${skipped}s");
	ok(adtsInfo($rest, 0), 'remainder starts on a frame');
	my (undef, $none) = adtsSkip($adts, 0);
	is($none, 0, 'skip 0');
}

# formatting
is(formatDuration(3723), '1:02:03', 'h:mm:ss');
is(formatDuration(59), '0:59', 'm:ss');
is(formatDuration(0), '', 'zero');
is(pictureUrl({ large => 'L', extra_large => 'XL' }), 'XL', 'largest picture');
is(pictureUrl(undef), undef, 'no pictures');

my $sections = [ { start => 0, song => 'a' }, { start => 300, song => 'b' }, { start => 600, song => 'c' } ];
is(trackAt($sections, 0)->{song}, 'a', 'track at 0');
is(trackAt($sections, 450)->{song}, 'b', 'track mid');
is(trackAt($sections, 9999)->{song}, 'c', 'last track');
is(trackAt([], 10), undef, 'no tracklist');

done_testing;
