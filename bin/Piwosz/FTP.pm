#!/usr/bin/perl


package Piwosz::FTP;

use IO::Socket;
use DBI;
use Data::Dumper;
use Crypt::GeneratePassword qw(chars);
use Data::Password qw(:all);
use feature 'switch';
use utf8;
use warnings;
use strict;

my $MINLEN = 10;
my $MAXLEN = 10;  
my $STARTUID= '2001';
my $STARTGID= '2001';

$|++;

$SIG{CHLD} = 'IGNORE';

sub new {
	my $class = shift;
	my $self = { @_	};
	my $dbh_system = $self->{dbh_system};
	$self->{ftp_add}   = $dbh_system->prepare("INSERT INTO ftpalluser (userid,passwd,uid,gid,homedir) VALUES(?,PASSWORD(?),?,?,?)");
	$self->{ftp_del}   = $dbh_system->prepare("UPDATE ftpalluser set status='n' WHERE userid=?");
	$self->{ftp_undel}   = $dbh_system->prepare("UPDATE ftpalluser set status='t' WHERE userid=?");
	$self->{ftp_list}  = $dbh_system->prepare("SELECT userid,uid,gid,homedir,bytes_in_avail,bytes_in_used,status FROM ftpalluser,ftpquotalimits,ftpquotatallies WHERE ftpalluser.userid=ftpquotalimits.name and ftpalluser.userid=ftpquotatallies.name");
	$self->{ftp_get}   = $dbh_system->prepare("SELECT userid,homedir,bytes_in_avail,bytes_out_avail,status FROM ftpalluser,ftpquotalimits WHERE ftpalluser.userid=ftpquotalimits.name and userid=? ");
	$self->{ftp_new_uid} = $dbh_system->prepare("SELECT MAX(uid)+1 from ftpalluser");
	$self->{ftp_new_gid} = $dbh_system->prepare("SELECT MAX(gid)+1 from ftpgroup");
	$self->{ftp_change_password} = $dbh_system->prepare("UPDATE ftpalluser SET passwd=PASSWORD(?) WHERE userid=?");
	$self->{ftp_change_limit} = $dbh_system->prepare("UPDATE ftpquotalimits SET bytes_in_avail=? WHERE name=?");
	
	bless $self, $class;
	return $self;
}

sub add {
	my($self,@args) = @_;
	my $client    = $self->{client};
	my $uid       = $self->{ftp_new_uid};
	my $gid       = $self->{ftp_new_gid};
	my $ftp_list  = $self->{ftp_list};
	my $ftp_get   = $self->{ftp_get};
	my $ftp_add   = $self->{ftp_add};
	$uid->execute();$uid=$uid->fetchrow() or $uid=$STARTUID;
	$gid->execute();$gid=$gid->fetchrow() or $gid=$STARTGID;
        my $user =  shift @args or return "Co ty kombinujesz? A gdzie nazwa uzytkownika?";
	$ftp_get->execute($user);
	my $row = $ftp_get->rows();
        my $dir  =  shift @args or return "Musisz podać katalog gdzie użytkownik będzie przechowywał swoje dane. Psssst to gdzieś w \033[1;32m/srv/www\033[0m)";
           $dir  =~ /^[\/~]/    or return "Fajnie gdybyś podał ścieżkę bezwględną, a nie jakieś \033[1;31m'$dir'\033[0m. Mam zgadywać?";
	my $gen=shift @args if (@args);
	return "Taki katalog już kiedyś robiłem.. więc coś jest nie tak!" if (-d $dir);
	return "Taki uzytkownik juz istnieje, wybierz innego" if ($row);
	mkdir $dir or return "Pojawiły się \033[1;31mbłędy\033[0m przy tworzeniu katalogu $dir";
	chown $uid,$gid,$dir or return "Pojawił się \033[1;31błąd\033[0m przy nadawaniu uprawnieniń"; 
	my $password=&_passwd($client,$gen);
	$ftp_add->execute($user,$password,$uid,$gid,$dir) or return "Nie mozna dodac do konta ftp: ($!)";
	return "Konto \033[1;32m$user\033[0m z hasełkiem \033[1;33m$password\033[0m zostało utworzone";
}

sub del {
	my($self,@args) = @_;
        my $uid     = $self->{uid};
	my $ftp_del   = $self->{ftp_del};
        my $user = shift @args  or return "Nie podałeś wymaganego argumentu (nazwy użytkownika)";
        $ftp_del->execute($user); 
	return "Użytkownik \033[1;32m$user\033[0m został zablokowany";
}

sub modify {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $client = $self->{client};
	
	my $ftp_get             = $self->{ftp_get};
	my $ftp_change_password = $self->{ftp_change_password};
	my $ftp_change_limit 	= $self->{ftp_change_limit};
	my $ftp_undel 		= $self->{ftp_undel};
	
        my $user = shift @args or return "Musisz podać nazwę użytkownika. Nie wiem kogo mam zmienić!";

        my $action = shift @args or return "Musisz podać nazwę czynności"; 
       	my $limit = shift @args;

        $ftp_get->execute($user);
	my $row = $ftp_get->rows;
	return "Wskazany użytkownik nie istenieje\n" unless ($row);
	 given($action) {
                when (/^(password|passwd|passwd)$/) {
                        my $password = &_passwd($client);
			$ftp_change_password->execute($password,$user);
                	return "\033[1;32m$user\033[0m ma teraz hasło \033[1;31m$password\033[0m";
		}
               	when (/^(unblock|undel)$/) {
			$ftp_undel->execute($user);
			return "Jeżeli \033[1;32m$user\033[0m był zablokowany to teraz już na pewno nie jest ;)";
		}               	
		when (/^(limit)$/) {
			return "Nie podałeś wymagane parametru" if (!$limit);	
			return "Limit wynosi $limit... muszę przerwać" if (!$limit);
			$ftp_change_limit->execute(($limit*1024*1024),$user);
			return "Użytkownik \033[1;32m$user\033[0m ma teraz limit \033[1;31m$limit\033[0m MB";
		} 
	}
	return;
}

sub list {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
        
	my $ftp_list = $self->{ftp_list};

        $ftp_list->execute;
        my $rows = $ftp_list->rows;
        return "Nie ma wódki - nie pije.. tzn. nie ma użytkowników." unless $rows;

	my $list = "\033[1;32mKonta FTP\033[0m ($rows użytkowników)\n\n";
	my($l_userid,$l_uid,$l_gid,$l_homedir,$l_limit,$l_uzyte,$l_status) = (
		length('Użytkownik'),
		length('UID'),
		length('GID'),  
		length('Katalog'),
		length('Limit (MB)'),
		length('Użyto (%)'), 
		length('Status'), 
        );
	my @table;
	while(my($userid,$uid,$gid,$homedir,$limit,$uzyte,$status) = $ftp_list->fetchrow_array) {
		
		$l_userid = length($userid) if length($userid) >$l_userid;
		$l_uid = length($uid) if length($uid) >$l_uid;
		$l_gid = length($gid) if length($gid) >$l_gid;
		$l_homedir = length($homedir) if length($homedir) >$l_homedir;
		$l_limit = length($limit) if length($limit) >$l_limit;
		$l_uzyte = length($uzyte) if length($uzyte) >$l_uzyte;
		if ($status eq 't') {
			$status="\033[1;32mOK\033[0m";
			$l_status = length($status) if length($status) >$l_status;
		} else {
			$status="\033[1;31mZABLOKOWANE\033[0m";
			$l_status = length($status) if length($status) >$l_status;
		}		
		push @table,[$userid,$uid,$gid,$homedir,$limit,$uzyte,$status];
	}
	my $top = "\033[1m" . sprintf("%-${l_userid}s","Użytkownik")." "x3
		.sprintf("%-${l_uid}s","UID")." "x3
		.sprintf("%-${l_gid}s","GID")." "x3
		.sprintf("%-${l_homedir}s","Katalog")." "x3
		.sprintf("%-${l_limit}s","Limit (MB)")." "x3
		.sprintf("%-${l_uzyte}s","Użyto (%)")." "x3
		.sprintf("%-${l_status}s","Status")."\033[0m\n";
		
	$list.=$top;
	
	foreach my $line (@table) {
		my($userid,$uid,$gid,$homedir,$limit,$uzyte,$status) = @$line;
		
		my $format = sprintf("%-${l_userid}s",$userid)." "x3
			   . sprintf("%-${l_uid}s",$uid)." "x3
			   . sprintf("%-${l_gid}s",$gid)." "x3
			   . sprintf("%-${l_homedir}s",$homedir)." "x3
			   . sprintf("%-${l_limit}s",&_bytes2mega($limit))." "x3
			   . sprintf("%-${l_uzyte}s",($uzyte/$limit*100))." "x3
			   . sprintf("%-${l_status}s",$status)."\n";
		$list .= $format;
	}

	return $list;
}
	
sub help {
	my($self,@args) = @_;
        my $uid    = $self->{uid};
        my $login  = $self->{login};
        my $client = $self->{client};
        my $usage  = "\033[1mPiwosz :: FTP\033[0m\n\n"
                   . "\033[1;32mSkładnia\033[0m\n"
                   . "  ftp add <login> <katalog>       	dodaje nowe konto\n"
                   . "  ftp del <login>                       usuwa (\033[01;31mblokuje\033[0m)konto\n"
                   . "  ftp list				wyświetla konto  (domyślne)\n"
                   . "  ftp change <login> password		zmienia hasło\n"
                   . "  ftp change <login> limit <wartość>	zmienia limit (wartość wyrażona w MB)\n\n"
                   . "  ftp change <login> unblock		odblokowuje użytkownika\n\n"
                   . "\033[1;32mGdzie\033[0m\n"
                   . "  <login> to login użytkownika do konta FTP\n"
                   . "  <katalog> to absolutna ścieżka do katalogu użytkownika\n"
                   . "\n\033[1;32mPrzykład\033[0m\n"
                   . "  piwosz ftp add gim5 /srv/www/gim5.jaworzno.edu.pl\n"
                   . "  piwosz ftp change gim5 password (gdzie password to metoda, a nie hasło dla użytkownika)\n"
                   . "  piwosz ftp change gim5 limit 500\n";
	return $usage;
}

sub _passwd {
        my($client,$switch) = @_;
        my($password);
	
	given($switch) {
		when ('0' || undef) {
			while (1) {
	                print $client "(PASS) \033[1mHasło\033[0m (lub wciśnij ENTER żeby wygenerować): "."\n";;
	                my $input = <$client>;
	                chomp $input;
	                if(! $input) {
	                        $password = chars(10, 10);
	                } else {
	                    $password = $input;
				}
			last		
	               }
		}
		default {
			$password=$switch;
		}
	}
	return $password;
}

sub _bytes2mega {
	my $size = shift;
	return $size/1024/1024
}

1;

