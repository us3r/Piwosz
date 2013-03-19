#!/usr/bin/perl

package Piwosz::WWW;

use IO::Socket;
use Crypt::GeneratePassword qw(chars);
use Data::Password qw(:all);
use feature 'switch';
use utf8;
use warnings;
use strict;

$|++;
$SIG{CHLD} = 'IGNORE';

sub new {
	my $class = shift;
	my $self = { @_ };
	bless $self, $class;
	return $self;
}

sub add {
	my ($self, @args) = @_;
	my $client = $self->{client};
	my $domena = shift(@args);
	return "Vhost \033[1;32m$domena\033[0m już istnieje. Wystaczy, że zmienisz jego status!"	if (-e "/etc/apache2/sites-available/$domena" ) ;

	open TPL,"/etc/apache2/template/vhost.tpl";
	my @template = <TPL>;
	my $plik = "@template";
	close TPL;
	$plik=~s/DOMENA/$domena/g;
	open DOM,">/etc/apache2/sites-available/$domena" or die "Nie mozna otworzyc dokument ($!)";
	print DOM $plik;
	close DOM;
	return "Vhost \033[1;32m$domena\033[0m została utworzona. Domyślnie domena jest wyłączona";
	return;
}


sub del {
	my ($self, @args) = @_;
	my $client = $self->{client};
	my $domena = shift(@args);
	return "Vhost \033[1;31m$domena\033[0m nie istnieje. W związku z tym nie mogę go usunąć!" if (! -e "/etc/apache2/sites-available/$domena" ) ;
	&disableSite($domena);
	system("rm","/etc/apache2/sites-available/$domena");
	return "Vhost \033[1;32m$domena\033[0m został usunięty";
}


sub modify {
	my ($self,@args) = @_;
	my $client = $self->{client};
	my $domena = shift @args or return "Musisz podać nazwę domeny";
	my $action = shift @args or return "Dla $domena musisz podać akcję";
	return "Taka domena nie istnieje" if (! -e "/etc/apache2/sites-available/$domena");
	given($action) {
		when(/^(enable|en)$/) {
			return "Domena jest już odblokowana" if ( -e "/etc/apache2/sites-enabled/$domena");
			my $ex = &enableSite($domena,$client);
			return "\033[01;32m$domena\033[0m - została odblokowana" if ($ex);

		}
		when (/^(dis|disable)$/) {
			return "Domena jest już zablokowana" if (! -e "/etc/apache2/sites-enabled/$domena");
			&disableSite($domena);
			return "\033[01;32m$domena\033[0m - została zablokowana";
		}

	}
	return;

}


sub list {
	my ($self, @args) = @_;
	my $client = $self->{client}; 
	opendir( my $dha, "/etc/apache2/sites-available");
	opendir( my $dhe, "/etc/apache2/sites-enabled");

	my @avail  = sort(( grep /[^\.|default]/, readdir($dha) ));
	my @enable = sort(( grep /[^\.|default]/, readdir($dhe) ));
	closedir($dha);
	closedir($dhe);

	my ($l_domena,$l_status) = ( length('Domena'),length('Status') );
	my $i_avail = @avail;
	my $i_enable = @enable;
	my $list = "\033[1;32mVhost's\033[0m ( ".--$i_enable." / ".--$i_avail." )\n\n";
	foreach(@avail) {
		$l_domena = length($_) if length($_) > $l_domena;
	};

	my $top = "\033[1m". sprintf ("%-${l_domena}s","Domena")." "x3
			   . sprintf ("%-${l_status}s","Status")."\033[0m\n";

	$list .= $top;

	foreach my $wpis (@avail)   {
		next if ($wpis =~ /default/);
		my $status = "\033[01;33mWyłączona\033[0m";
		$status = "\033[01;32mWłączona\033[0m" if (grep { $_ eq $wpis }  @enable);
		my $format = sprintf("%-${l_domena}s",$wpis)." "x3
			   . sprintf("%-${l_status}s",$status)."\n";
		$list .= $format;
	}


	return $list;
}

sub enableSite {
	my ($domena,$client) = @_ ;
	if (-e "/srv/www/$domena") {
		system("a2ensite", "$domena");
		system("/etc/init.d/apache2", "reload");
		return 1;
	} else {
		print $client "\033[01;33m [ OSTRZEŻENIE ] Katalog /srv/www/$domena nie istnieje, dodaj konto FTP i dopiero aktywuj domene\n!"; 
		return 0;
	}
}


sub disableSite {
	my $domena = shift ;
	system("a2dissite", $domena);
	system("/etc/init.d/apache2", "reload");
}


	
sub help {
	my($self,@args) = @_;
        my $client = $self->{client};
        my $usage  = "\033[1mPiwosz :: WWW\033[0m\n\n"
                   . "\033[1;32mSkładnia\033[0m\n"
                   . "  www add <domena>	  	     	dodaje nową domene\n"
                   . "  www del <domena>			usuwa daną domenę\n"
                   . "  www list				wyświetla domeny i ich statusy  (domyślne)\n"
                   . "  www modify <domena> enable		aktywuje domenę\n"
                   . "  www modify <domena> disable		deaktywuję domenę\n\n"
                   . "\033[1;32mGdzie\033[0m\n"
                   . "  <domena> to adres URL bez WWW\n"
                   . "\n\033[1;32mPrzykład\033[0m\n"
                   . "  piwosz www add gim5.jaworzno.edu.pl\n"
                   . "  piwosz www change gim5.jaworzno.edu.pl enable\n"
                   . "  piwosz www change gim5.jaworzno.edu.pl disable\n";
	return $usage;
}

1



__DATA__
<VirtualHost *:80>
	ServerName  DOMENA 
	ServerAdmin admin@jaworzno.edu.pl
	ServerAlias www.DOMENA

	DocumentRoot /srv/www/DOMENA
	
	<Directory /srv/www/DOMENA>
		Options FollowSymLinks MultiViews
		AllowOverride None
		Order allow,deny
		allow from all
	</Directory>


	ErrorLog /var/log/apache2/logs/DOMENA.error.log

	LogLevel warn

	CustomLog /var/log/apache2/logs/DOMENA.access.log combined

</VirtualHost>


