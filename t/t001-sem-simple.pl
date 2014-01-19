#!/usr/bin/env perl

use strict;
use warnings;
#use POSIX ":sys_wait_h";

my @dissem_server = qw(../dissem.pl);
my $dissem_client = '../dissem.pl';

my $server_pid;
my $child_pid;

$server_pid = fork();
die unless defined $server_pid;

if ($server_pid == 0) {
	# child: start server
	# exit(0); # here to test with failed server.
	exec @dissem_server or die "error: can't exec server: $!";
}


$SIG{ALRM} = sub { kill('KILL', $server_pid) if $server_pid;  die "error: test timeout"; };
alarm(3);

select undef,undef,undef,0.01;

my $rc1 = system $dissem_client, qw/sem SEM001 1/;
warn "client1 has problem: $? (rc=$rc1)" if $?;

my $rc2 = system $dissem_client, qw/sem SEM001 -1/;
warn "client2 has problem: $? (rc=$rc2)" if $?;

my $rc3 = kill(0,$server_pid);

# sleep 10; # here to test blocked client.

if ($rc1 == 0 && $rc2 == 0 && $rc3 == 1) {
	kill('TERM', $server_pid);
	warn "OK\n";
	exit(0);
} else {
	kill('KILL', $server_pid);
	die "test failed: rc1==$rc1, rc2==$rc2, server_ok==$rc3";
}

