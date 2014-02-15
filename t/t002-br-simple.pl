#!/usr/bin/env perl

use strict;
use warnings;

my @dissem_server = qw(../dissem.pl --server);
my $dissem_client = '../dissem.pl';

my $server_pid;
my @child_pids;

$SIG{CHLD} = 'IGNORE';

$server_pid = &start_bg( 'server', @dissem_server );

&fsleep( 0.1 );

my $N = 2;
for my $i (1 .. $N) {
	my $child_pid = &start_bg( "client$i", $dissem_client, qw/barrier BR001/, $N );
	push @child_pids, $child_pid;
}

&fsleep( 0.2 );

my $rc0 = kill(0,$server_pid);
my $ch_count = kill(0,@child_pids);

kill 'TERM', $server_pid, @child_pids;

if ($rc0 == 1 && $ch_count == 0) {
	warn "OK\n";
	exit(0);
} else {
	die "test failed: server_ok==$rc0, child_count=$ch_count";
}

sub start_bg
{
	my ($name, @cmd) = @_;

	my $pid = fork();
	die unless defined $pid;

	if ($pid == 0) {
		exec @cmd or die "error: can't exec $name: $! (cmd: @cmd)";
	}
	warn "started $name (cmd: @cmd)";
	return $pid;
}

sub fsleep
{
	select undef,undef,undef,$_[0];
}
