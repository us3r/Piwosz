#!/usr/bin/perl

use IO::Socket;
use DBI;
use Data::Dumper;
use feature 'switch';
use YAML qw(LoadFile);
use warnings;
use strict;
use utf8;
use lib '/home/koneser/PIWOSZ/bin';
use Piwosz::FTP;
use Piwosz::WWW;
use Piwosz::LDAP;

$|++;
$SIG{CHLD} = 'IGNORE'; 
my $conf = YAML::LoadFile('/home/koneser/PIWOSZ/conf/piwosz.yaml');
unless (@ARGV) {
	open STDOUT,">>",$conf->{'log'}->{'access'};
	open STDERR,">>",$conf->{'log'}->{'error'};
}

my $sockfile = $conf->{'sock'};
`rm -f -- $conf->{'log'}->{'lock'}/*`;
unlink $sockfile;

my $socket = new IO::Socket::UNIX (
        Local => $sockfile,
        Type => SOCK_STREAM,
        Listen => 10,
        Reuse => 1,
);
die "Nie moge utworzyc socketa: $!\n" unless $socket;
chmod 0666, $sockfile;
chown 0,100,$sockfile;
binmode( $socket, ':utf8' );

# dbi 
my $dbh_system = DBI->connect("dbi:ldap:proftpd;mysql_read_default_file=".$conf->{
'mysql'}->{'path'}."",undef,undef,{ RaiseError => 0, AutoCommit => 1 });

$dbh_system->{mysql_auto_reconnect} = 1;
$dbh_system->{mysql_enable_utf8} = 1;

## main 
while(my $client = $socket->accept()) {
        binmode( $client, ':utf8' );
        setsockopt $client, SOL_SOCKET, SO_PASSCRED, 1;
        my($pid,$uid,$gid) = unpack "iii", $client->sockopt(SO_PEERCRED);
	my $now = localtime(time);
        if(not defined $uid) {
                print "[$now] WARNING: UID nie jest zdefiniowany!\n";
                close($client);
                next;
        }
	if($uid != 1000) {
		print "[$now] WARNING: UID $uid nie jest uprawniony!\n";
		close($client);
		next;
	}
        if(fork() == 0) {
                if(-f "$conf->{'sock'}/$uid" and $uid) {
			print "[$now] Połączenie odrzucone. Ten uid ($uid) już pije z piwoszem.\n";
                        print $client "Tylko jeden użytkownik może w danym momencie pić z piwoszem. Bleeeee.\n";
                        close($client);
                        exit 0;
                } else {
                        open LOCK,">",$conf->{'log'}->{'lock'}.'/'.$uid;
                        close LOCK;
                }
                $client->autoflush(1);
                my $login = getpwuid($uid);
                if(not defined $login) {
			print "[$now] ERROR: Brak przypisania $uid do nazwy!\n";
                        print $client "Żem sie tak nawalił, że nie pamiętam Twojego imienia?\n";
                        close($client);
                        next;
                }

                while(<$client>) {
                        chomp;
                        my @args = split(/\s/,$_);
			my $pwd    = shift @args;
			my $daemon = shift @args || 'help';
			my @params = ($uid,$login,$client,@args);
			my $now = localtime(time);
                        print "[$now] Zapytanie: $login ($uid), Odpowiedz: $daemon(".join(' ',@args).")\n";
			my $return;
			given($daemon) {
				when ("ftp") { 
					my $ftp = Piwosz::FTP->new(
						login      => $login,
						uid        => $uid,
						client     => $client,
						dbh_system => $dbh_system
					);
					
					## commands
					my $command = shift @args || 'list';
					   $command = 'help' if grep(/^(help|\?)$/,@args);

					given($command) {
						when ('add')               { $return = $ftp->add(@args)    }
						when ('del')               { $return = $ftp->del(@args)    }
						when ('list')              { $return = $ftp->list(@args)   }
						when (/^(change|modify)$/) { $return = $ftp->modify(@args) }
						when ('help')              { $return = $ftp->help(@args)   }
						default {
							print $client "Ni cholery nie pamiętam żebym znał takie polecenie jak '$command'.\n";
							print $client "Wysil się i przeczytaj \033[1;34mpiwosz ftp help.\n";
						}
					}				
				}

				when ("www") {
					my $www = Piwosz::WWW->new(
						login	=> $login,
						uid	=> $uid,
						client  => $client
					);
					## commands
					my $command = shift @args || 'list';
					   $command = 'help' if grep(/^(help|\?)$/,@args);
					
					given ($command) {
						when ('add')               { $return = $www->add(@args)    }
						when ('del')               { $return = $www->del(@args)    }
						when ('list')              { $return = $www->list(@args)   }
						when ('modify')              { $return = $www->modify(@args)   }
						when ('help')              { $return = $www->help(@args)   }
						default {
							print $client "Ni cholery nie pamiętam żebym znał takie polecenie jak '$command'.\n";
							print $client "Wysil się i przeczytaj \033[1;34mpiwosz www help.\n";
						}
					}	
				}
				## Help
				when ("help") {
					my $usage  = "\033[1mPiwosz, zarządzca usług wszelakich :)\033[0m\n"
					           . "Sposób użycia: piwosz [USŁUGA] [ARGS]\n\n"
                                                   . "Dostępne usługi: \033[1;32mftp www\033[0m\n"
					           . "Wpisz help jako argument usługi aby zobaczyć szczegóły:\n"
					           . "\033[1;34m\$ piwosz www help\033[0m\n\n";
					print $client $usage;
				}
				default {
					print $client "Dostępne usługi to ftp www\n";
				}
			}
			print $client $return."\n" if $return;
			last;
                }
                close($client);
                unlink $conf->{'log'}->{'lock'}.'/'.$uid;
		exit;
        }
}
close($socket);
close STDOUT;
close STDERR;
