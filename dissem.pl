#!/usr/bin/env perl

# barrier BR001 2
# sem SM001 1
# sem SM001 -1
# sem SM001 0

use warnings;
use strict;

#use POSIX
#use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Select;
use IO::Socket::INET;
use Storable qw(nfreeze thaw);
use Data::Dumper;
use Socket qw/MSG_WAITALL IPPROTO_TCP TCP_NODELAY/;
# MSG_WAITALL: non-blocking sockets appear to be not-portable


my %sema;
my %brr;
my %cli;
my %err_cli_list;

my $verbose = 1;

my $sel = IO::Select->new();

if (@ARGV) {
	warn "cli: @ARGV\n";
	exit( cli_proc(@ARGV) );
} else {
	warn "srv loop\n";
	srv_loop();
}

sub srv_loop
{

	my $ss = IO::Socket::INET->new(
		'LocalAddr'=>'0.0.0.0:11399', 
		'Proto' => 'tcp',
		'Blocking' => 0,
		'Listen' => 1,
		'ReuseAddr' => 1,
	);

	$sel->add( $ss );

	my $count_x2 = 100;

	while(1)
	{
		my @socks = $sel->can_read( 60 );

		#warn "timeout? h=@{[$sel->handles()]}" unless @socks;

		my $check_fini = 0;
		for my $sock (@socks) {
			if ($sock ne $ss) {
				my $cli = $cli{$sock};
				die unless defined $cli;
				warn "srv: sock: ".$sock;
				my $rc = proc_cli_readable( $cli );
				if ($rc eq 'OK') {
					# nothing to do
				}
				else {
					$check_fini++;
				}
			}
			else {
				my $new_cli = $ss->accept();
				die unless $new_cli;
				warn "srv: have new client: $new_cli\n";
    				setsockopt($new_cli, IPPROTO_TCP, TCP_NODELAY, 1);
				#sock_non_block( $new_cli );
				$cli{ $new_cli } = { s => $new_cli, st => 'C' };
				$sel->add( $new_cli );
				next;
			}
		}
		check_cli_fini() if $check_fini;

		die if $count_x2-- < 0;
	}
}

sub send_cli_msg
{
	my ($cli, @opts) = @_;
	my $s = $cli->{s};

	return unless @opts;

	my $resp;
	if (@opts == 1) {
		$resp = { msg => "".$opts[0] };
	}
	elsif (@opts % 2 == 0) {
		my %resp = @opts;
		die unless exists $resp{msg};
		$resp = \%resp;
	}
	else {
		die "internal error";
	}
	
	send_message( $s, 'srv', $resp );
}

sub end_cli
{
	my ($cli, @msg) = @_;

	my $s = $cli->{s};

	unless (exists($cli{$s})) {
		warn "srv: end_cli: bad socket: '".$s."'";
		return;
	}

	warn "srv: end_cli: ".$s." with [@msg]";

	send_cli_msg( $cli, @msg ) if @msg;

	$sel->remove( $s );

	my $rc;
	$rc = $s->shutdown(2);
	die "srv: shutdown: ".$s.": $!" unless defined($rc);

	$rc = $s->close();
	die "srv: close: ".$s.": $!" unless defined($rc);

	delete $cli{$s};
}


sub check_cli_fini
{
	my %fini_cli_list;

	for my $br (values %brr) {
		if ($br->{error}) {
			$err_cli_list{$_} = [$_, 'ERR'] for @{$br->{clients}};
			#@err_cli_list{@{$br->{clients}}} = @{$br->{clients}};
			$br->{clients} = [];
		}
		elsif ($br->{finished}) {
			$fini_cli_list{$_} = [$_, 'DONE'] for @{$br->{clients}};
			$br->{clients} = [];
		}
	}

	for my $sema (values %sema) {
		$fini_cli_list{$_} = [$_, "DONE ".$sema->{count}] for @{$sema->{fini_cli}};
		$sema->{fini_cli} = [];
	}

	# send final message
	send_cli_msg( @$_ ) for values %err_cli_list;
	send_cli_msg( @$_ ) for values %fini_cli_list;

	# close connections
	end_cli( $_->[0] ) for values %err_cli_list;
	end_cli( $_->[0] ) for values %fini_cli_list;
}


sub proc_br
{
	my ($cli, $name, $count) = @_;

	my $br;
	if (exists $brr{$name}) {
		$br = $brr{$name};
	}
	else {
		$br = {
			name => $name,
			count_wait => $count,
			count_current => 0,
			clients => [],
			finished => 0,
			error => 0,
		};
		$brr{$name} = $br;
	}

	my @dummy = grep { $_ eq $cli } (@{$br->{clients}});
	die "double client [$cli] internal error" if @dummy;


	# client is on the barrier. all errors below are fatal.
	push @{$br->{clients}}, $cli;

	if ($br->{error}) {
		return 'ERR';
	}

	if (!defined($count) || $br->{count_wait} != $count) {
		# fatal: clients disagree on the count
		$br->{error} = 'Inconsistent count';
		return 'ERR';
	}

	$br->{count_current}++;

	if ($br->{count_current} >= $br->{count_wait}) {
		$br->{finished} = 1;
		return 'DONE';
	}
	else {
		return 'OK';
	}
}

sub proc_sema
{
	my ($cli, $name, $count) = @_;

	my $sema;
	if (exists $sema{$name}) {
		$sema = $sema{$name};
	}
	else {
		$sema = {
			name => $name,
			count => 0,
			clients => [],
			cli_fini => []
		};
		$sema{$name} = $sema;
	}


	my $new_count = $sema->{count} + $count;

	if ($new_count < 0) {
		# client must block
		push @{$sema->{clients}}, [$cli, $count];
		warn "srv: sema: ".$cli->{s}.": blocks for $count @ ".$sema->{count};
		return 'OK';
	}
	else {
		# this client can go on
		$sema->{count} = $new_count;
		push @{$sema->{fini_cli}}, $cli;

		warn "srv: sema: ".$cli->{s}.": is ok for $count @ ".$sema->{count};

		# some other clients too.
		while ( @{$sema->{clients}} ) {
			my ($cli2, $count2) = @{$sema->{clients}->[0]};
			last unless $sema->{count} + $count2 >= 0;
			warn "srv: sema: ".$cli2->{s}.": is ok for $count2 @ ".$sema->{count};
			$sema->{count} += $count2;
			push @{$sema->{fini_cli}}, $cli2;
			pop @{$sema->{clients}};
		}
		return 'DONE';
	}

}

my $count_x1 = 0;

sub proc_cli_readable
{
	my ($cli) = @_;
	my $s = $cli->{s};
	
	my $hash_ref;
	eval { $hash_ref = recv_message( $s, 'srv' ); };
	warn "$@" if $@;

	my ($cmd, $name, $count) = @$hash_ref{qw/cmd name count/};

	if (!defined($cmd) || !defined($name)) {
		return 'ERR';
	}

	if ($cmd eq 'barrier') {
		return proc_br( $cli, $name, $count );
	}
	elsif ($cmd eq 'sem' || $cmd eq 'sema' || $cmd eq 'semaphore') {
		return proc_sema( $cli, $name, $count );
	}
	else {
		end_cli( $cli, 'ERR bad object: '.$cmd );
		return 'ERR';
	}
}



###	sub sock_non_block
###	{
###		my ($sock) = @_;
###	
###	
###		my $flags = fcntl($sock, F_GETFL, 0)
###				or die "Can't get flags for the socket: $!\n";
###		$flags = fcntl($sock, F_SETFL, $flags | O_NONBLOCK)
###				or die "Can't set flags for the socket: $!\n";
###	}


# barrier BR001 2
sub cli_proc
{
	my ($cmd, $name, $count) = @_;

	my %req = ( cmd => $cmd, name => $name, count => $count );

	my $sock = IO::Socket::INET->new( 'PeerAddr'=>'localhost:11399', 'Proto' => 'tcp' );
	die 'cli: connect error' unless $sock;
	setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, 1);

	my $rc;
	my $data;

	eval { send_message( $sock, 'cli', \%req ); };
	die "$@" if $@;

	my $hash_ref;
	eval { $hash_ref = recv_message( $sock, 'cli' ); };
	die "$@" if $@;


	if (exists $hash_ref->{msg}) {
		if ($hash_ref->{msg} =~ /^DONE/) {
			if ($hash_ref->{msg} ne 'DONE') {
				(my $msg = $hash_ref->{msg}) =~ s!^DONE\s+!!;
				print $msg, "\n";
			}
			return 0;
		}
		else {
			return 1;
		}
	} else {
		die 'cli: unknown response: ', Dumper( $hash_ref ), "\n";
	}
}


sub recv_message
{
	my ($sock, $ctx) = @_;
	$ctx = '' unless defined $ctx;

	my $rc;
	my $data;

	$rc = $sock->recv( $data, 4, MSG_WAITALL );
	die "$ctx: recv error: $!" unless defined $rc;
	if (length($data) == 0) {
		warn "$ctx: EOF";
		return undef;
	}
	die "$ctx: short recv (".length($data)." != 4)"
		unless length($data) == 4;

	warn "$ctx: recvd bytes:".length($data) if $verbose;
	
	my $len = unpack( 'N', $data );
	die "$ctx: bad len: $len" if $len < 10 || $len > 16*1024;

	$rc = $sock->recv( $data, $len, MSG_WAITALL );
	die "$ctx: recv error: $!" unless defined $rc;
	if (length($data) == 0) {
		die "$ctx: unexpected EOF";
	}
	die "$ctx: short recv (".length($data)." != $len)"
		unless length($data) == $len;
	warn "$ctx: recvd bytes:".length($data) if $verbose;

	my $hash_ref = thaw( $data );
	die "$ctx: bad message" unless defined $hash_ref;
	die "$ctx: bad message" unless ref($hash_ref) eq 'HASH';

	return $hash_ref;
}

sub send_message
{
	my $sock = shift;
	my $ctx = shift;
	my $rreq = ref($_[0]) eq 'HASH' ? $_[0] : { @_ };

	my $bin_hash = nfreeze( $rreq );
	my $bin = pack( 'N', length($bin_hash) ) . $bin_hash;

	warn "$ctx: sending ".length($bin_hash)." bytes." if $verbose;
	my $rc = $sock->send( $bin );
	die "$ctx: send error: $!" unless defined $rc;
	die "$ctx: short send ($rc != ".length($bin).")" unless $rc == length($bin);

	return 1;
}
