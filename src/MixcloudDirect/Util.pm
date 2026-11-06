package Plugins::MixcloudDirect::Util;

# Pure helpers (no LMS dependencies) so they can be unit tested:
# stream-url decoding, HLS playlist parsing, MPEG-TS -> ADTS demuxing,
# ADTS frame walking for accurate seeks, and formatting.

use strict;
use utf8;

use Exporter qw(import);
use MIME::Base64 qw(decode_base64);

our @EXPORT_OK = qw(
	decodeStreamUrl parseKey cloudcastUrl
	parseMasterPlaylist parseMediaPlaylist pickVariant segmentAt
	tsToAdts adtsInfo adtsSkip
	formatDuration pictureUrl trackAt
);

# Mixcloud's GraphQL streamInfo urls are base64 of (url XOR this key).
use constant STREAM_KEY => 'IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD';

sub decodeStreamUrl {
	my $encoded = shift;
	return unless defined $encoded && length $encoded;

	my $bytes = decode_base64($encoded);
	my $key   = STREAM_KEY;
	my $klen  = length $key;

	my $out = '';
	for my $i (0 .. length($bytes) - 1) {
		$out .= chr(ord(substr($bytes, $i, 1)) ^ ord(substr($key, $i % $klen, 1)));
	}

	return $out =~ m{^https?://} ? $out : undef;
}

# "/user/slug/" or "https://www.mixcloud.com/user/slug/" -> (user, slug)
sub parseKey {
	my $key = shift || return;
	$key =~ s{^https?://(?:www\.|m\.|beta\.)?mixcloud\.com}{}i;
	$key =~ s{[?#].*$}{};
	my ($user, $slug) = $key =~ m{^/?([^/]+)/([^/]+)/?$} or return;
	return if $slug =~ /^(?:uploads|favorites|listens|playlists|stream|followers|following)$/;
	return ($user, $slug);
}

sub cloudcastUrl {
	my ($user, $slug) = @_;
	return "mcdirect://$user/$slug";
}

# -> [ { bandwidth => 192001, url => '...' }, ... ], best first
sub parseMasterPlaylist {
	my ($text, $base) = @_;
	my @variants;
	my $bandwidth;

	for my $line (split /\r?\n/, $text || '') {
		if ($line =~ /^#EXT-X-STREAM-INF:(.*)/) {
			($bandwidth) = $1 =~ /(?:^|,)BANDWIDTH=(\d+)/;
			$bandwidth ||= 0;
		}
		elsif (defined $bandwidth && $line =~ /^[^#\s]/) {
			push @variants, { bandwidth => $bandwidth, url => _absolute($line, $base) };
			undef $bandwidth;
		}
	}

	return [ sort { $b->{bandwidth} <=> $a->{bandwidth} } @variants ];
}

# Highest variant at or under $maxBandwidth (or the lowest if none fit)
sub pickVariant {
	my ($variants, $maxBandwidth) = @_;
	return unless $variants && @$variants;
	my ($pick) = grep { !$maxBandwidth || $_->{bandwidth} <= $maxBandwidth } @$variants;
	return $pick || $variants->[-1];
}

# -> [ { start => secs, duration => secs, url => '...' }, ... ]
sub parseMediaPlaylist {
	my ($text, $base) = @_;
	my @segments;
	my ($duration, $start) = (undef, 0);

	for my $line (split /\r?\n/, $text || '') {
		if ($line =~ /^#EXTINF:\s*([\d.]+)/) {
			$duration = $1;
		}
		elsif (defined $duration && $line =~ /^[^#\s]/) {
			push @segments, { start => $start, duration => $duration, url => _absolute($line, $base) };
			$start += $duration;
			undef $duration;
		}
	}

	return \@segments;
}

# index of the segment holding $secs, and how far into it that is
sub segmentAt {
	my ($segments, $secs) = @_;
	return (0, 0) unless $secs && $secs > 0;

	for my $i (0 .. $#$segments) {
		my $s = $segments->[$i];
		return ($i, $secs - $s->{start}) if $secs < $s->{start} + $s->{duration};
	}
	return (scalar @$segments, 0);    # past the end
}

sub _absolute {
	my ($url, $base) = @_;
	return $url if $url =~ m{^https?://}i || !$base;
	if ($url =~ m{^/}) {
		my ($root) = $base =~ m{^(https?://[^/]+)}i;
		return $root . $url;
	}
	(my $dir = $base) =~ s{[?#].*$}{};
	$dir =~ s{[^/]*$}{};
	return $dir . $url;
}

# Pull the audio elementary stream (ADTS AAC for Mixcloud's HLS) out of
# MPEG-TS packets. $state carries the audio PID across segments.
sub tsToAdts {
	my ($data, $state) = @_;
	$state ||= {};

	use bytes;
	my $out = '';
	my $len = length $data;

	for (my $pos = 0; $pos + 188 <= $len; $pos += 188) {
		if (substr($data, $pos, 1) ne "\x47") {
			# lost sync: find the next packet start
			my $next = index($data, "\x47", $pos + 1);
			last if $next < 0;
			$pos = $next - 188;
			next;
		}

		my ($b1, $b2, $b3) = unpack('x C C C', substr($data, $pos, 4));
		my $pid   = (($b1 & 0x1f) << 8) | $b2;
		my $start = $b1 & 0x40;
		my $afc   = ($b3 >> 4) & 3;

		next unless $afc & 1;    # no payload

		my $off = 4;
		$off += 1 + ord(substr($data, $pos + 4, 1)) if $afc & 2;
		next if $off >= 188;

		my $payload = substr($data, $pos + $off, 188 - $off);

		if ($start && substr($payload, 0, 3) eq "\0\0\1") {
			my $streamId = ord(substr($payload, 3, 1));
			if ($streamId >= 0xc0 && $streamId <= 0xdf) {
				$state->{pid} = $pid unless defined $state->{pid};
			}
			next unless defined $state->{pid} && $pid == $state->{pid};
			my $headerLen = ord(substr($payload, 8, 1));
			$payload = substr($payload, 9 + $headerLen);
		}
		elsif (!defined $state->{pid} || $pid != $state->{pid}) {
			next;
		}

		$out .= $payload;
	}

	return $out;
}

my @SAMPLE_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350);

# ADTS header at $pos -> { length, samplerate, channels } or undef
sub adtsInfo {
	my ($buf, $pos) = @_;
	$pos ||= 0;

	use bytes;
	return if $pos + 7 > length $buf;

	my @h = unpack('C7', substr($buf, $pos, 7));
	return unless $h[0] == 0xff && ($h[1] & 0xf6) == 0xf0;

	my $rate = $SAMPLE_RATES[($h[2] >> 2) & 0x0f] || return;
	my $length = (($h[3] & 0x03) << 11) | ($h[4] << 3) | ($h[5] >> 5);
	return if $length < 7;

	return {
		length     => $length,
		samplerate => $rate,
		channels   => (($h[2] & 1) << 2) | ($h[3] >> 6),
		frames     => ($h[6] & 3) + 1,
	};
}

# Drop whole frames worth $secs from the front of an ADTS buffer
# -> (remaining buffer, seconds actually skipped)
sub adtsSkip {
	my ($buf, $secs) = @_;

	use bytes;
	my ($pos, $skipped) = (0, 0);

	while ($skipped < $secs) {
		my $frame = adtsInfo($buf, $pos) || last;
		last if $pos + $frame->{length} > length $buf;
		$pos += $frame->{length};
		$skipped += 1024 * $frame->{frames} / $frame->{samplerate};
	}

	return (substr($buf, $pos), $skipped);
}

sub formatDuration {
	my $secs = int(shift || 0);
	return '' unless $secs > 0;
	my $h = int($secs / 3600);
	my $m = int(($secs % 3600) / 60);
	return $h ? sprintf('%d:%02d:%02d', $h, $m, $secs % 60) : sprintf('%d:%02d', $m, $secs % 60);
}

# Mixcloud pictures hash -> the largest square image it offers
sub pictureUrl {
	my $pictures = shift || return;
	for my $size (qw(1024wx1024h 768wx768h 640wx640h extra_large large medium)) {
		return $pictures->{$size} if $pictures->{$size};
	}
	return;
}

# Tracklist entry playing at $secs (sections sorted by start)
sub trackAt {
	my ($sections, $secs) = @_;
	my $current;
	for my $s (@{ $sections || [] }) {
		last if $s->{start} > $secs;
		$current = $s;
	}
	return $current;
}

1;
