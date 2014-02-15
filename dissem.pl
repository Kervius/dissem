#!/usr/bin/env perl

use warnings;
use strict;

use IO::Select;
use IO::Socket::INET;
use Storable qw(nfreeze thaw);
use Data::Dumper;
use Socket qw/MSG_WAITALL IPPROTO_TCP TCP_NODELAY/;
#use POSIX
#use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
# MSG_WAITALL: non-blocking sockets appear to be not-portable

use Getopt::Long qw/GetOptionsFromArray/;


my @config_files = ("/etc/dissem.conf", "/usr/local/etc/dissem.conf", ($ENV{HOME} ? $ENV{HOME}."/.dissem.conf" : ()));
my $opt_server_mode = 0;
my $opt_server_addr = 'localhost';
my $opt_listen_addr = '0.0.0.0';
my $opt_port = 11399;
my $opt_command = '';
my $opt_name = '';
my $opt_count = 0;
my $opt_verbose = 0;
my $opt_cli_block_on_error = 0;

exit(usage(0)) unless @ARGV;
my @opt_list = load_opts( @ARGV );

#warn "xxx: @opt_list";
warn "all opts: @opt_list" if "@opt_list" =~ /--verbose/; # a hack.

Getopt::Long::Configure('require_order');
GetOptionsFromArray(
	\@opt_list,
	'server' => \$opt_server_mode,	# --server
	'address|A=s' => \$opt_server_addr,	# --addr=<serveraddr>
	'listen=s' => \$opt_listen_addr,	# --listen=<bind-addr>
	'port|p=i' => \$opt_port,		# --port=<port>
	'command|object=s' => \$opt_command,
	'name=s' => \$opt_name,
	'count=i' => \$opt_count,
	'block-on-error|H' => \$opt_cli_block_on_error,
	'verbose|v' => sub { $opt_verbose++; },
	'quiet|q' => sub { $opt_verbose-- if $opt_verbose; },
	'help|h' => sub { exit(usage(0)); },
) or exit(usage(1));

unless ($opt_command && $opt_name) {
	# support traditional client syntax: dissem sem <name> <count>
	($opt_command, $opt_name, $opt_count) = @opt_list if @opt_list == 3;
};


my %sema;
my %brr;
my %cli;
my %err_cli_list;

my $verbose = 1;

my $sel = IO::Select->new();

if ($opt_server_mode) {
	warn "srv loop\n" if $opt_verbose;
	srv_loop();
}
else {
	warn "cli: $opt_command $opt_name $opt_count\n" if $opt_verbose;
	exit( cli_proc($opt_command, $opt_name, $opt_count) );
}

sub srv_loop
{

	my $ss = IO::Socket::INET->new(
		'LocalAddr' => $opt_listen_addr,
		'LocalPort' => $opt_port,
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
				warn "srv: sock: ".$sock if $opt_verbose;
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
				if ($new_cli) {
					warn "srv: have new client: $new_cli\n" if $opt_verbose;
					setsockopt($new_cli, IPPROTO_TCP, TCP_NODELAY, 1);
					#sock_non_block( $new_cli );
					$cli{ $new_cli } = { s => $new_cli, st => 'C' };
					$sel->add( $new_cli );
				}
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
		die "internal error: bad @opts" unless exists $resp{msg};
		$resp = \%resp;
	}
	else {
		die "internal error: bad @opts";
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

	warn "srv: end_cli: ".$s." with [@msg]" if $opt_verbose;

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
		warn "srv: sema: ".$cli->{s}.": blocks for $count @ ".$sema->{count} if $opt_verbose;
		return 'OK';
	}
	else {
		# this client can go on
		$sema->{count} = $new_count;
		push @{$sema->{fini_cli}}, $cli;

		warn "srv: sema: ".$cli->{s}.": is ok for $count @ ".$sema->{count} if $opt_verbose;

		# some other clients too.
		while ( @{$sema->{clients}} ) {
			my ($cli2, $count2) = @{$sema->{clients}->[0]};
			last unless $sema->{count} + $count2 >= 0;
			warn "srv: sema: ".$cli2->{s}.": is ok for $count2 @ ".$sema->{count} if $opt_verbose;
			$sema->{count} += $count2;
			push @{$sema->{fini_cli}}, $cli2;
			pop @{$sema->{clients}};
		}
		return 'DONE';
	}

}

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

	if ($cmd eq 'barrier' || $cmd eq 'br') {
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

sub cli_done
{
	my ($rc, $msg) = @_;
	if ($rc) {
		warn "$msg\n" if $msg;
		if ($opt_cli_block_on_error) {
			while(1) { sleep; };
		}
	}
	else {
	}
	return $rc;
}

sub cli_proc
{
	my ($cmd, $name, $count) = @_;

	my %req = ( cmd => $cmd, name => $name, count => $count );

	my $sock = IO::Socket::INET->new( 'PeerAddr'=>$opt_server_addr, PeerPort => $opt_port, 'Proto' => 'tcp' );
	die 'cli: connect error' unless $sock;
	setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, 1);

	my $rc;
	my $data;

	eval { send_message( $sock, 'cli', \%req ); };
	return cli_done( 3, "cli: send: $@" ) if $@;

	my $hash_ref;
	eval { $hash_ref = recv_message( $sock, 'cli' ); };
	return cli_done( 3, "cli: recv: $@" ) if $@;


	if (exists $hash_ref->{msg}) {
		if ($hash_ref->{msg} =~ /^DONE/) {
			if ($hash_ref->{msg} ne 'DONE') {
				(my $msg = $hash_ref->{msg}) =~ s!^DONE\s+!!;
				print $msg, "\n";
			}
			return cli_done( 0 );
		}
		else {
			return cli_done( 1, $hash_ref->{msg} );
		}
	} else {
		return cli_done( 2, 'cli: unknown response: '.Dumper( $hash_ref ) );
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

	warn "$ctx: recvd bytes:".length($data) if $opt_verbose;
	
	my $len = unpack( 'N', $data );
	die "$ctx: bad len: $len" if $len < 10 || $len > 16*1024;

	$rc = $sock->recv( $data, $len, MSG_WAITALL );
	die "$ctx: recv error: $!" unless defined $rc;
	if (length($data) == 0) {
		die "$ctx: unexpected EOF";
	}
	die "$ctx: short recv (".length($data)." != $len)"
		unless length($data) == $len;
	warn "$ctx: recvd bytes:".length($data) if $opt_verbose;

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

	warn "$ctx: sending ".length($bin_hash)." bytes." if $opt_verbose;
	my $rc = $sock->send( $bin );
	die "$ctx: send error: $!" unless defined $rc;
	die "$ctx: short send ($rc != ".length($bin).")" unless $rc == length($bin);

	return 1;
}

sub usage
{
	my ($rc) = @_;
	print <<EEEE;

dissem. Simple client/server semaphore. Usage:

	Server mode:
		dissem --server
	Client:
		dissem sem test1 -1
		dissem --object sem --namee test1 --count=-1

	Summary of command-line options:
	--server	Server mode. Doesn't daemonize.
	--listen <IP>	Listen addr for the server

	--port|-p <N>	Port number server/client should use

	--addr|-A <IP>	IP of the dissem server client should use
	--command <S>	
	--object <S>	Command/object type client is ran for.
			'semaphore'/'sema'/'sem' for semaphore,
			or 'barrier'/'br' for barrier.
	--name <S>	Name of the object
	--count <N>	The object-specific count/number.
	--block-on-error|-H	Client should block on any errorr.
	--verbose|-v	Increment verbosity level.
	--quiet|-q	Decrement verbosity level

EEEE
	return $rc;
}

sub load_opts
{
	my (@argv) = @_;
	my @ret;

	my @extra_files;
	my $env_flags='';

	if ($ENV{DISSEM_FLAGS}) {
		my $tmp = $ENV{DISSEM_FLAGS};
		if ($tmp =~ s!^@!!) {
			push @extra_files, $tmp;
		} else {
			$env_flags = $tmp;
		}
	}

	for my $grc (@config_files, @extra_files) {
		next unless -f $grc && -r $grc && -s $grc;
		open my $f, '<', $grc or next;
		while (<$f>) {
			chomp;
			next if /^\s*#/; # comments
			next if /^\s*$/;
			push @ret, $_;
		}
		undef $f;
	}

	if ($env_flags) {
		push @ret, split /\s+/, $env_flags;
	}

	push @ret, @ARGV;
	return @ret;
}
