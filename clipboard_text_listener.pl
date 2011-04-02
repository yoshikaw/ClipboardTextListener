#!/usr/bin/perl

use strict;
use warnings;

package ClipboardTextListener::Writer;
use Encode qw(decode encode);
use Encode::Guess qw(euc-jp shiftjis 7bit-jis);
{
    my %command = (
        # defines available command to copy stdin to the clipboard
        # osname      command-path              options
        darwin   => { '/usr/bin/pbcopy'      => '',
        },
        linux    => { '/usr/bin/xsel'        => '',
                      '/usr/bin/xclip'       => '',
        },
        cygwin   => { '/usr/bin/putclip'     => '',
        },
        MSWin32  => { ($ENV{WINDIR}||='').'\\system32\\clip.exe' => '',
        },
    );
    sub new {
        my ($class, $opts) = @_;
        my $self = bless {
            writer   => _create(),
            encoding => $opts->{encoding},
            verbose  => $opts->{verbose},
        }, $class;
        $self
    }
    sub write {
        my ($self, $text_data) = @_;
        return unless $text_data;
        my $guess = guess_encoding($text_data);
        my $text_encoding = ref $guess ? $guess->name : ($guess =~ /([\w-]+)$/o)[0];
        if ($self->{verbose} ge 2) {
            printf "(Encoding: %s -> %s)\n" , $text_encoding, $self->{encoding};
            printf "%s\n", $text_data
                if ref $self->{writer} ne 'ClipboardTextListener::Writer::Stdout';
        }
        $text_data = encode($self->{encoding}, decode($text_encoding, $text_data));
        $self->{writer}->_write($text_data);
    }
    sub _create {
        if ($^O =~ /^(darwin|linux)$/) {
            return ClipboardTextListener::Writer::Cmd->new($command{$1});
        }
        if ($^O =~ /^(MSWin32|cygwin)$/) {
            eval {
                require Win32::Clipboard;
            };
            if ($@) {
                # tries to use command
                return ClipboardTextListener::Writer::Cmd->new($command{$1});
            }
            else {
                return ClipboardTextListener::Writer::Win32->new;
            }
        }
        print "Platform: $^O is not supported yet. echo received text only.\n";
        return ClipboardTextListener::Writer::Stdout->new;
    }
}

package ClipboardTextListener::Writer::Win32;
{
    sub new {
        my $class = shift;
        my $self = bless {
            clipboard => Win32::Clipboard(),
        }, $class;
        $self
    }
    sub _write {
        my ($self, $textdata) = @_;
        $self->{clipboard}->Set($textdata);
    }
}

package ClipboardTextListener::Writer::Cmd;
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
    sub _write {
        my ($self, $textdata) = @_;
        open COPYCMD, "| $self->{cmd} $self->{opts}";
        print COPYCMD $textdata;
        close COPYCMD;
    }
}

package ClipboardTextListener::Writer::Stdout;
{
    sub new {
        my $class = shift;
        return bless {}, $class;
    }
    sub _write {
        my ($self, $textdata) = @_;
        print "$textdata\n";
    }
}

package ClipboardTextListener;
use IO::Socket qw(inet_ntoa unpack_sockaddr_in);
{
    sub new {
        my $class = shift;
        my %args = @_;
        my $self = {
            listen_addr => $args{-addr}     ||= 'localhost',
            listen_port => $args{-port}     ||= 52224,
            encoding    => $args{-encoding} ||= 'shiftjis',
            verbose     => $args{-verbose}  ||= 0,
            accept_key  => $args{-key}      ||= 'change_on_install',
            _args       => @_ ? join(' ', @_) : '',
        };
        return bless $self, $class;
    }
    sub run {
        my $self = shift;

        my $writer = ClipboardTextListener::Writer->new({
            encoding => $self->{encoding},
            verbose  => $self->{verbose},
        });

        my $listen_sock = new IO::Socket::INET(
            Listen    => 5,
            LocalAddr => $self->{listen_addr},
            LocalPort => $self->{listen_port},
            Proto     => 'tcp',
            Reuse     => 1,
        );
        die "IO::Socket : $!" unless $listen_sock;

        $self->_stdout(sprintf "listening %s:%d %s"
                             , $self->{listen_addr}, $self->{listen_port}
                             , $self->{_args} ? "($self->{_args})" : ""
        );

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
            my $text_data = join '', @data;
            if ($self->{verbose}) {
                my ($src_port, $src_iaddr) = unpack_sockaddr_in($sock->peername);
                $self->_stdout(
                    sprintf '(%s:%s) %s'
                          , inet_ntoa($src_iaddr), $src_port
                          , $accepted ? '*** RECIEVE TEXT *** ' . length($text_data)
                                      : '*** NOT ACCEPTED ***'
                );
            }
            close $sock;
            $writer->write($text_data);
        }
        close $listen_sock;
    }
    sub _stdout {
        my ($self, $message) = @_;
        if ($self->{verbose}) {
            my @dt = (localtime)[0..5]; $dt[5] += 1900; $dt[4] += 1;
            printf '%04d/%02d/%02d %02d:%02d:%02d ', reverse @dt;
        }
        printf '%s[%d]: %s', __PACKAGE__, $$, $message;
        print "\n";
    }
}

if (__FILE__ eq $0) {
    ClipboardTextListener->new(@ARGV)->run;
}

1;
