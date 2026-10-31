#!/usr/bin/env perl
#
# Minimaler HTTP/HTTPS-Proxy für apt im Tolaria-Container.
#
# Hintergrund: In manchen LXC-Setups ignoriert apt /etc/hosts, obwohl getent
# den gepinnten Eintrag sieht. Dieser Proxy lauscht nur auf 127.0.0.1, löst
# Zielhosts über eine Mapping-Datei (Host -> IP) auf und leitet HTTP sowie
# HTTPS-CONNECT dorthin weiter. Damit braucht apt selbst gar kein DNS.
#
# Usage:
#   apt-proxy.pl --port 3142 --map /tmp/apt-hosts.map
#
# Mapping-Datei: pro Zeile "host ip" (IPv4 bevorzugt).
#
use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;
use Getopt::Long;

my $port = 3142;
my $mapfile = "/tmp/tolaria-apt-hosts.map";
GetOptions("port=i" => \$port, "map=s" => \$mapfile)
    or die "Usage: $0 [--port N] [--map FILE]\n";

my %map;
if (open my $fh, '<', $mapfile) {
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*(#|$)/;
        my ($host, $ip) = split /\s+/, $line;
        next unless defined $host && defined $ip;
        $host = lc $host;
        my $list = $map{$host} //= [];
        push @$list, $ip unless grep { $_ eq $ip } @$list;
    }
    close $fh;
}

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 32,
    Reuse     => 1,
) or die "listen on 127.0.0.1:$port failed: $!\n";

$SIG{CHLD} = 'IGNORE';

while (my $client = $server->accept) {
    my $pid = fork();
    if (!defined $pid) {
        close $client;
        next;
    }
    if ($pid) {
        close $client;
        next;
    }
    close $server;
    eval { handle_client($client, \%map) };
    close $client;
    exit 0;
}

sub connect_upstream {
    my ($host, $port, $map) = @_;
    my $ips = $map->{lc $host};
    if ($ips) {
        for my $addr (@$ips) {
            my $sock = IO::Socket::INET->new(
                PeerAddr => $addr,
                PeerPort => $port,
                Proto    => 'tcp',
                Timeout  => 20,
            );
            return $sock if $sock;
        }
        # Keine der gepinnten IPs erreichbar: nicht heimlich auf DNS
        # ausweichen, sonst verschleiert der Proxy nur das eigentliche Problem.
        return;
    }
    return IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 20,
    );
}

sub relay_bidirectional {
    my ($a, $b) = @_;
    my $sel = IO::Select->new($a, $b);
    while (1) {
        my @ready = $sel->can_read(60);
        last unless @ready;
        for my $sock (@ready) {
            my $buf;
            my $n = sysread($sock, $buf, 65536);
            last if !defined $n || $n == 0;
            my $other = (fileno($sock) == fileno($a)) ? $b : $a;
            my $off = 0;
            while ($off < $n) {
                my $w = syswrite($other, $buf, $n - $off, $off);
                last unless defined $w && $w > 0;
                $off += $w;
            }
            return if $off < $n;
        }
    }
}

sub handle_client {
    my ($client, $map) = @_;
    $client->autoflush(1);
    my $request = <$client>;
    return unless defined $request;
    my ($method, $target, $proto) = split(/\s+/, $request);
    return unless defined $method && defined $target;
    $proto //= 'HTTP/1.1';

    if (uc $method eq 'CONNECT') {
        # apt sendet nach der CONNECT-Zeile noch Header (mind. Host:).
        # Diese müssen konsumiert werden, sonst landen sie vor dem
        # TLS-ClientHello beim Zielserver und die Zertifikatsprüfung scheitert.
        while (my $line = <$client>) {
            last if $line =~ /^\r?\n$/;
        }
        my ($host, $port) = split(/:/, $target, 2);
        $port //= 443;
        my $up = connect_upstream($host, $port, $map);
        if (!$up) {
            print $client "HTTP/1.1 502 Bad Gateway\r\n\r\n";
            return;
        }
        print $client "HTTP/1.1 200 Connection established\r\n\r\n";
        relay_bidirectional($client, $up);
        close $up;
        return;
    }

    return unless uc $method eq 'GET' || uc $method eq 'HEAD';
    my ($host, $port, $path) = parse_url($target);
    return unless defined $host;

    my $up = connect_upstream($host, $port, $map);
    if (!$up) {
        print $client "HTTP/1.1 502 Bad Gateway\r\n\r\n";
        return;
    }
    $up->autoflush(1);

    print $up "$method $path $proto\r\n";
    my $host_header = ($port == 80) ? $host : "$host:$port";
    my $saw_host = 0;
    while (my $line = <$client>) {
        last if $line =~ /^\r?\n$/;
        next if $line =~ /^Proxy-Connection:/i;
        $saw_host = 1 if $line =~ /^Host:/i;
        print $up $line;
    }
    print $up "Host: $host_header\r\n" unless $saw_host;
    print $up "Connection: close\r\n\r\n";

    my $buf;
    while (1) {
        my $n = sysread($up, $buf, 65536);
        last unless defined $n && $n > 0;
        print $client $buf;
    }
    close $up;
}

sub parse_url {
    my ($url) = @_;
    if ($url =~ m{^http://([^/:]+)(?::(\d+))?(/.*)?$}i) {
        my $host = lc $1;
        my $port = $2 // 80;
        my $path = $3 // '/';
        return ($host, $port, $path);
    }
    return;
}
