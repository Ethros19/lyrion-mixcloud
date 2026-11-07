package Plugins::MixcloudDirect::Util;

# Pure helpers (no LMS dependencies) so they can be unit tested:
# stream-url decoding, HLS playlist parsing, MPEG-TS -> ADTS demuxing,
# ADTS frame walking for accurate seeks, and formatting.

use strict;
use utf8;

use Exporter qw(import);
use MIME::Base64 qw(decode_base64);

our @EXPORT_OK = qw(
	decodeStreamUrl parseKey cloudcastUrl parseLiveKey liveUrl
	parseMasterPlaylist parseMediaPlaylist pickVariant segmentAt
	audioRendition parseLivePlaylist
	tsToAdts adtsInfo adtsSkip
	mp4AudioConfig fmp4Samples adtsHeader fmp4ToAdts
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
	return if $user eq 'live';    # /live/<user>/ is a live stream (parseLiveKey)
	return if $slug =~ /^(?:uploads|favorites|listens|playlists|stream|followers|following)$/;
	return ($user, $slug);
}

# "/live/<user>/" or "https://www.mixcloud.com/live/<user>/?utm..." -> user
sub parseLiveKey {
	my $key = shift || return;
	$key =~ s{^https?://(?:www\.|m\.|beta\.)?mixcloud\.com}{}i;
	$key =~ s{[?#].*$}{};
	my ($user) = $key =~ m{^/?live/([^/]+)/?$} or return;
	return $user;
}

sub liveUrl { "mcdirect://live/$_[0]" }

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

# Live masters carry video variants plus a separate audio-only rendition
# (#EXT-X-MEDIA:TYPE=AUDIO,...,URI="index-audio.m3u8"): its absolute url
sub audioRendition {
	my ($text, $base) = @_;
	my ($fallback, $default);
	for my $line (split /\r?\n/, $text || '') {
		next unless $line =~ /^#EXT-X-MEDIA:(.*)/ && $1 =~ /(?:^|,)TYPE=AUDIO(?:,|$)/;
		my ($uri) = $line =~ /URI="([^"]+)"/ or next;
		$fallback ||= $uri;
		$default ||= $uri if $line =~ /DEFAULT=YES/;
	}
	my $uri = $default || $fallback;
	return $uri ? _absolute($uri, $base) : undef;
}

# Live media playlist -> { sequence, target, map, ended, segments => [{ seq, duration, url }] }
sub parseLivePlaylist {
	my ($text, $base) = @_;
	my %pl = (sequence => 0, target => 2, segments => [], ended => 0);
	my $duration;

	for my $line (split /\r?\n/, $text || '') {
		if    ($line =~ /^#EXT-X-MEDIA-SEQUENCE:\s*(\d+)/)  { $pl{sequence} = $1 }
		elsif ($line =~ /^#EXT-X-TARGETDURATION:\s*([\d.]+)/) { $pl{target} = $1 }
		elsif ($line =~ /^#EXT-X-MAP:.*URI="([^"]+)"/)      { $pl{map} = _absolute($1, $base) }
		elsif ($line =~ /^#EXT-X-ENDLIST/)                  { $pl{ended} = 1 }
		elsif ($line =~ /^#EXTINF:\s*([\d.]+)/)             { $duration = $1 }
		elsif (defined $duration && $line =~ /^[^#\s]/) {
			push @{ $pl{segments} }, {
				# Mixcloud's sequence numbers are ~1.8e15: fine as 64-bit integers
				seq      => $pl{sequence} + @{ $pl{segments} },
				duration => $duration,
				url      => _absolute($line, $base),
			};
			undef $duration;
		}
	}
	return \%pl;
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

# -- fragmented MP4 (CMAF) audio, as in Mixcloud live streams ------------

sub _boxes {
	my ($buf, $start, $end) = @_;
	use bytes;
	my @out;
	my $pos = $start;
	while ($pos + 8 <= $end) {
		my ($size, $type) = unpack('N a4', substr($buf, $pos, 8));
		my $header = 8;
		if ($size == 1) {
			my ($hi, $lo) = unpack('N N', substr($buf, $pos + 8, 8));
			$size = $hi * 4294967296 + $lo;
			$header = 16;
		}
		elsif ($size == 0) {
			$size = $end - $pos;
		}
		last if $size < $header || $pos + $size > $end;
		push @out, { type => $type, start => $pos, body => $pos + $header, end => $pos + $size };
		$pos += $size;
	}
	return @out;
}

sub _child {
	my ($buf, $box, @path) = @_;
	for my $type (@path) {
		($box) = grep { $_->{type} eq $type } _boxes($buf, $box->{body}, $box->{end});
		return unless $box;
	}
	return $box;
}

# MPEG-4 descriptor length: 1-4 bytes, 7 bits each
sub _descLen {
	my ($buf, $pos) = @_;
	my $len = 0;
	for (1 .. 4) {
		my $b = ord(substr($buf, $$pos++, 1));
		$len = ($len << 7) | ($b & 0x7f);
		last unless $b & 0x80;
	}
	return $len;
}

# init segment -> { object, rateIndex, samplerate, channels, timescale, bitrate }
sub mp4AudioConfig {
	my $buf = shift;
	use bytes;
	return unless defined $buf;

	my ($moov) = grep { $_->{type} eq 'moov' } _boxes($buf, 0, length $buf) or return;
	my $trak = _child($buf, $moov, 'trak') or return;
	my $mdhd = _child($buf, $trak, 'mdia', 'mdhd');
	my $stsd = _child($buf, $trak, 'mdia', 'minf', 'stbl', 'stsd') or return;

	my $timescale;
	if ($mdhd) {
		my $version = ord(substr($buf, $mdhd->{body}, 1));
		$timescale = unpack('N', substr($buf, $mdhd->{body} + ($version ? 20 : 12), 4));
	}

	# stsd: version/flags(4) count(4), then the mp4a sample entry: 8 header +
	# 28 bytes of audio sample entry fields, then its child boxes (esds)
	my ($mp4a) = grep { $_->{type} eq 'mp4a' } _boxes($buf, $stsd->{body} + 8, $stsd->{end}) or return;
	my ($esds) = grep { $_->{type} eq 'esds' } _boxes($buf, $mp4a->{body} + 28, $mp4a->{end}) or return;

	my $pos = $esds->{body} + 4;                      # version/flags
	return unless ord(substr($buf, $pos++, 1)) == 0x03; # ES_Descriptor
	_descLen($buf, \$pos);
	$pos += 2;                                        # ES_ID
	my $flags = ord(substr($buf, $pos++, 1));
	$pos += 2 if $flags & 0x80;                       # dependsOn_ES_ID
	$pos += 1 + ord(substr($buf, $pos, 1)) if $flags & 0x40;   # URL
	$pos += 2 if $flags & 0x20;                       # OCR_ES_Id
	return unless ord(substr($buf, $pos++, 1)) == 0x04; # DecoderConfigDescriptor
	_descLen($buf, \$pos);
	my $bitrate = unpack('N', substr($buf, $pos + 9, 4));   # avgBitrate (0 = variable)
	$pos += 13;                                       # objectType ... avgBitrate
	return unless ord(substr($buf, $pos++, 1)) == 0x05; # DecoderSpecificInfo
	my $len = _descLen($buf, \$pos);
	return unless $len >= 2;

	# AudioSpecificConfig: 5 bits object type, 4 bits rate index, 4 bits channels
	my $asc = unpack('n', substr($buf, $pos, 2));
	my $object    = $asc >> 11;
	my $rateIndex = ($asc >> 7) & 0x0f;
	my $channels  = ($asc >> 3) & 0x0f;
	return if $object == 31 || $rateIndex == 15;      # escape values: not seen, not handled

	return {
		object     => $object,
		rateIndex  => $rateIndex,
		samplerate => $SAMPLE_RATES[$rateIndex],
		channels   => $channels,
		timescale  => $timescale,
		bitrate    => $bitrate || undef,
	};
}

# media segment -> list of raw AAC frames (one per sample)
sub fmp4Samples {
	my $buf = shift;
	use bytes;
	my @samples;

	for my $moof (grep { $_->{type} eq 'moof' } _boxes($buf, 0, length $buf)) {
		for my $traf (grep { $_->{type} eq 'traf' } _boxes($buf, $moof->{body}, $moof->{end})) {
			my ($tfhd) = grep { $_->{type} eq 'tfhd' } _boxes($buf, $traf->{body}, $traf->{end}) or next;

			my $tf = unpack('N', substr($buf, $tfhd->{body}, 4)) & 0xffffff;
			my $p = $tfhd->{body} + 8;                # version/flags + track_ID
			my $base = $moof->{start};                # default-base-is-moof (CMAF)
			if ($tf & 0x01) {
				my ($hi, $lo) = unpack('N N', substr($buf, $p, 8));
				$base = $hi * 4294967296 + $lo;
				$p += 8;
			}
			$p += 4 if $tf & 0x02;                    # sample_description_index
			$p += 4 if $tf & 0x08;                    # default_sample_duration
			my $defaultSize = $tf & 0x10 ? unpack('N', substr($buf, $p, 4)) : 0;

			my $offset = $base;
			for my $trun (grep { $_->{type} eq 'trun' } _boxes($buf, $traf->{body}, $traf->{end})) {
				my $f = unpack('N', substr($buf, $trun->{body}, 4)) & 0xffffff;
				my $count = unpack('N', substr($buf, $trun->{body} + 4, 4));
				my $q = $trun->{body} + 8;
				if ($f & 0x01) {
					$offset = $base + unpack('l>', substr($buf, $q, 4));
					$q += 4;
				}
				$q += 4 if $f & 0x04;                 # first_sample_flags

				for (1 .. $count) {
					$q += 4 if $f & 0x100;            # duration
					my $size = $defaultSize;
					if ($f & 0x200) { $size = unpack('N', substr($buf, $q, 4)); $q += 4 }
					$q += 4 if $f & 0x400;            # flags
					$q += 4 if $f & 0x800;            # composition offset
					last if $offset + $size > length $buf;
					push @samples, substr($buf, $offset, $size);
					$offset += $size;
				}
			}
		}
	}

	return @samples;
}

# 7-byte ADTS header for one raw AAC frame
sub adtsHeader {
	my ($config, $len) = @_;
	my $full = $len + 7;
	my $profile = ($config->{object} - 1) & 0x03;
	return pack('C7',
		0xff,
		0xf1,                                         # MPEG-4, layer 0, no CRC
		($profile << 6) | ($config->{rateIndex} << 2) | (($config->{channels} >> 2) & 1),
		(($config->{channels} & 3) << 6) | (($full >> 11) & 3),
		($full >> 3) & 0xff,
		(($full & 7) << 5) | 0x1f,                    # buffer fullness 0x7FF (VBR)
		0xfc,                                         # ... and one raw data block
	);
}

sub fmp4ToAdts {
	my ($segment, $config) = @_;
	return join '', map { adtsHeader($config, length $_) . $_ } fmp4Samples($segment);
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
