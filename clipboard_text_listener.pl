#!/usr/bin/perl

use strict;
use warnings;

package Writer;
use Encode qw(decode encode);
use Encode::Guess qw(euc-jp shiftjis 7bit-jis);
{
    # defines available command line to copy stdin to the clipboard
    my %command = (
        # osname      command line
        darwin   => [ '/usr/bin/pbcopy', ],
        linux    => [ '/usr/bin/xsel', '/usr/bin/xclip', ],
        cygwin   => [ '/usr/bin/putclip', ],
        MSWin32  => [ ($ENV{WINDIR}||='').'\\system32\\clip.exe',
                      ($ENV{CYGWIN_HOME}||='').'\\usr\\bin\\putclip.exe', ],
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
        my ($self, $text) = @_;
        return unless $text;
        my $guess = guess_encoding($text);
        my $text_encoding = ref $guess
            ? $guess->name
            : ($guess =~ /([\w-]+)$/o)[0]; # accept first suspects
        if ($self->{verbose} ge 2) {
            printf "(Encoding: %s -> %s)\n" , $text_encoding, $self->{encoding};
            printf "%s\n", $text
                if ref $self->{writer} ne 'Writer::Writer::Stdout';
        }
        $text = encode($self->{encoding}, decode($text_encoding, $text));
        $self->{writer}->_write($text);
    }
    sub _create {
        if ($^O =~ /^(darwin|linux)$/) {
            return Writer::Clipboard::Cmd->new($command{$1});
        }
        if ($^O =~ /^(MSWin32|cygwin)$/) {
            eval {
                require Win32::Clipboard;
            };
            if ($@) {
                # tries to use command
                return Writer::Clipboard::Cmd->new($command{$1});
            }
            return Writer::Clipboard::Win32->new;
        }
        print "Platform: $^O is not supported yet. echo received text only.\n";
        return Writer::Stdout->new;
    }
}

package Writer::Clipboard::Win32;
{
    sub new {
        my $class = shift;
        my $self = bless {
            clipboard => Win32::Clipboard(),
        }, $class;
        $self
    }
    sub _write {
        my ($self, $text) = @_;
        $self->{clipboard}->Set($text);
    }
}

package Writer::Clipboard::Cmd;
{
    sub new {
        my ($class, $cmdref) = @_;
        my (@tried_cmd, $cmd, $available) = ();
        for my $cmdline (@$cmdref) {
            # check the first field at command line whether or not to be available
            $cmd = (split /\s+/, $cmdline)[0];
            if (-x $cmd) {
                $available = $cmdline;
                last;
            }
            push @tried_cmd, $cmd;
        }
        $available or die sprintf "command not found(%s).", join(', ', @tried_cmd);
        my $self = bless {
            cmdline => $available,
        }, $class;
        $self
    }
    sub _write {
        my ($self, $text) = @_;
        open COPYCMD, "| $self->{cmdline}";
        print COPYCMD $text;
        close COPYCMD;
    }
}

package Writer::Stdout;
{
    sub new {
        my $class = shift;
        return bless {}, $class;
    }
    sub _write {
        my ($self, $text) = @_;
        print "$text\n";
    }
}

package TextListener;
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
        my $writer = Writer->new({
            encoding => $self->{encoding},
            verbose  => $self->{verbose},
        });
        my $listen_sock = new IO::Socket::INET(
            LocalAddr => $self->{listen_addr},
            LocalPort => $self->{listen_port},
            Proto     => 'tcp',
            Listen    => 1,
            ReuseAddr => 1,
        );
        die "IO::Socket : $!" unless $listen_sock;

        $self->_stdout(sprintf "listening %s:%d %s"
                             , $self->{listen_addr}, $self->{listen_port}
                             , $self->{_args} ? "($self->{_args})" : ""
        );

        my ($sock, $accepted, @data, %header);
        while ($sock = $listen_sock->accept) {
            select $sock; $|=1; select STDOUT;
            @data = (); $accepted = 0;
            while (<$sock>) {
                if ($accepted) {
                    push @data, $_;
                }
                else {
                    my @header = split /\t/;
                    my $received_key = shift @header;
                    last unless $received_key =~ /^\Q$self->{accept_key}\E$/o;
                    %header = map { split /=/ } @header;
                    $accepted = 1;
                }
            }
            my $text = join '', @data;
            if ($self->{verbose}) {
                my ($src_port, $src_iaddr) = unpack_sockaddr_in($sock->peername);
                $self->_stdout(
                    sprintf '(%s:%s) %s'
                          , inet_ntoa($src_iaddr), $src_port
                          , $accepted ? '*** RECEIVE TEXT *** ' . length($text) # roughly
                                      : '*** NOT ACCEPTED ***'
                );
            }
            close $sock;
            $writer->write($text);
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
    TextListener->new(@ARGV)->run;
}

1;
