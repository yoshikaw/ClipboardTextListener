#!/usr/bin/perl

package ClipboardTextListener::Client;
{
    sub new {
        return ClipboardTextListener::Client::Win32->new if $^O =~ /^(MSWin32|cygwin)$/;
        return ClipboardTextListener::Client::Cmd->new({qw(/usr/bin/pbcopy '')}) if $^O =~ /^(darwin)$/;
        return ClipboardTextListener::Client::Cmd->new({qw(/usr/bin/xsel ''), qw(/usr/bin/xclip '')}) if $^O =~ /^(linux)$/;
        return ClipboardTextListener::Client::Stdout->new;
    }
    sub write { print "not implement yet!\n" }
    sub read { print "not implement yet!\n" }
}
package ClipboardTextListener::Client::Win32;
use base qw(ClipboardTextListener::Client);
{
    require Win32::Clipboard if $^O =~ /^(MSWin32|cygwin)$/;
    sub new {
        my $class = shift;
        my $self = bless {
            clipboard => Win32::Clipboard,
        }, $class;
        $self
    }
    sub write {
        my ($self, $textdata) = @_;
        $self->{clipboard}->Set($textdata);
    }
}
package ClipboardTextListener::Client::Cmd;
use base qw(ClipboardTextListener::Client);
{
    sub new {
        my ($class, $cmdref) = @_;
        my (@cmd, @tried_cmd) = ();
        while (my ($cmd, $opts) = each %$cmdref) {
            if (-x $cmd) {
                @cmd = ($cmd, $opts);
                last;
            }
            else {
                push @tried_cmd, $cmd;
            }
        }
        @cmd or die sprintf "Can\'t execute copy command(%s).", join(', ', @tried_cmd);
        my $self = bless {
            cmd  => $cmd[0],
            opts => $cmd[1],
        }, $class;
        $self
    }
    sub write {
        my ($self, $textdata) = @_;
        open COPYCMD, "| $self->{cmd} $self->{opts}";
        print COPYCMD $textdata;
        close COPYCMD;
    }
}
package ClipboardTextListener::Client::Stdout;
use base qw(ClipboardTextListener::Client);
{
    sub new {
        my $class = shift;
        return bless {}, $class;
    }
    sub write {
        my ($self, $textdata) = @_;
        print "$textdata\n";
    }
}
package ClipboardTextListener;
{
    use strict;
    use utf8;
    use warnings;

    use Encode qw(decode encode);
    use Encode::Guess qw(euc-jp shiftjis 7bit-jis);
    use IO::Socket qw(inet_ntoa unpack_sockaddr_in);

    sub new {
        my $class = shift;
        my %args = @_;
        my $self = {
            listen_addr     => $args{-addr}     ||= 'localhost',
            listen_port     => $args{-port}     ||= 52224,
            output_encoding => $args{-encoding} ||= 'shiftjis',
            verbose         => $args{-verbose}  ||= 0,
            accept_key      => $args{-key}      ||= 'change_on_install',
            client          => ClipboardTextListener::Client->new,
        };
        return bless $self, $class;
    }

    sub run {
        my $self = shift;
        my $listen_sock = new IO::Socket::INET(
            Listen    => 5,
            LocalAddr => $self->{listen_addr},
            LocalPort => $self->{listen_port},
            Proto     => 'tcp',
            Reuse     => 1,
        );
        die "IO::Socket : $!" unless $listen_sock;

        print "$0 @ARGV\n";
        print "[$$] listening $self->{listen_addr}:$self->{listen_port} \n";

        my ($sock, $accepted, @data);
        while ($sock = $listen_sock->accept) {
            select $sock; $|=1; select STDOUT;
            @data = (); $accepted = 0;
            while (<$sock>) {
                if ($accepted) {
                    push @data, $_;
                }
                else {
                    last unless /^\Q$self->{accept_key}\E$/o;
                    $accepted = 1;
                }
            }
            if ($self->{verbose}) {
                my ($client_port, $client_iaddr) = unpack_sockaddr_in($sock->peername);
                my $client_ip = inet_ntoa($client_iaddr);
                my @dt = (localtime)[0..5]; $dt[5] += 1900; $dt[4] += 1;
                printf '%04d/%02d/%02d %02d:%02d:%02d ', reverse @dt;
                printf '[%s:%s] ', $client_ip, $client_port;
                if ($accepted) {
                    print @data if $self->{verbose} ge 2;
                }
                else {
                    print '*** NOT ACCEPTED ***';
                }
                print "\n";
            }
            close $sock;
            if (@data) {
                my $text_data = join '', @data;
                my $guess = guess_encoding($text_data);
                my $encoding = ref $guess ? $guess->name : ($guess =~ /([\w-]+)$/o)[0];
                $text_data = encode($self->{output_encoding}, decode($encoding, $text_data));
                $self->{client}->write($text_data);
            }
        }
        close $listen_sock;
    }
}

if (__FILE__ eq $0) {
    ClipboardTextListener->new(@ARGV)->run;
}

1;
