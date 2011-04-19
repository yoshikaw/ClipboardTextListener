#!/usr/bin/perl

use strict;
use warnings;

package WriterFactory;
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
    sub create {
        my ($self, $type) = @_;
        my $notifier = _createNotifier();
        if ($type eq 'clipboard') {
            if ($^O =~ /^(MSWin32|cygwin)$/) {
                eval { require Win32::Clipboard; };
                unless ($@) {
                    return Writer::Clipboard::Win32->new($notifier);
                }
            }
            my $executable = _findExecutable($command{$^O});
            if ($executable) {
                return Writer::Clipboard::Cmd->new($notifier, $executable);
            }
        }
        print "Platform: $^O is not supported yet. echo received text only.\n";
        return Writer->new($notifier);
    }
    sub _createNotifier {
        if ($^O =~ /^(MSWin32|cygwin)$/) {
            eval { require Win32::GUI; };
            unless ($@) {
                return Notifier::Win32->new;
            }
        }
        my $executable;
        if ($^O =~ /^(darwin)$/) {
            $executable = _findExecutable([`which growlnotify`]);
            if ($executable) {
                return Notifier::Cmd->new(
                    qq{| $executable -a "%s" -t "%s"}
                );
            }
        }
        if ($^O =~ /^(linux)$/) {
            $executable = _findExecutable([`which notify-send`]);
            if ($executable) {
                return Notifier::Cmd->new(
                    qq{$executable "%s" "%s"}
                );
            }
            $executable = _findExecutable([`which xmessage`]);
            if ($executable) {
                return Notifier::Cmd->new(
                    qq{$executable -button '' -timeout 1 "%s\n" "%s"}
                );
            }
        }
        return Notifier->new;
    }
    sub _findExecutable {
        my $cmdlines = shift;
        for my $cmdline (@$cmdlines) {
            chomp $cmdline;
            # check the first field at command line whether or not to be available
            return $cmdline if -x (split /\s+/, $cmdline)[0];
        }
    }
}

package Writer;
{
    sub new {
        my ($class, $notifier) = @_;
        return bless { notifier => $notifier }, $class;
    }
    sub write {
        my ($self, $text) = @_;
        print "$text\n";
    }
    sub notify {
        my ($self, $info) = @_;
        $self->{notifier}->notify($info);
    }
}

package Writer::Clipboard::Win32;
use base qw(Writer);
{
    sub new {
        my ($class, $notifier) = @_;
        my $self = bless {
            notifier  => $notifier,
            clipboard => Win32::Clipboard(),
        }, $class;
        $self
    }
    sub write {
        my ($self, $text) = @_;
        $self->{clipboard}->Set($text);
    }
}

package Writer::Clipboard::Cmd;
use base qw(Writer);
{
    sub new {
        my ($class, $notifier, $cmdline) = @_;
        my $self = bless {
            notifier => $notifier,
            cmdline  => $cmdline,
        }, $class;
        $self
    }
    sub write {
        my ($self, $text) = @_;
        open my $cmd, "| $self->{cmdline}";
        print $cmd $text;
        close $cmd;
    }
}

package Notifier;
{
    sub new {
        bless {}, shift
    }
    sub notify {}
}

package Notifier::Win32;
use base qw(Notifier);
{
    sub new {
        bless {}, shift
    }
    sub notify {
        my ($self, $info) = @_;
        my $ni = Win32::GUI::Window->new->AddNotifyIcon(
            -balloon       => 1,
            -balloon_icon  => $info->{icon} || 'none', # none/info/warning/error
            -balloon_title => $info->{title},
            -balloon_tip   => $info->{text},
        );
        sleep 1; # display interval
    }
}

package Notifier::Cmd;
use base qw(Notifier);
{
    sub new {
        my ($class, $format) = @_;
        my $self = bless {
            format  => $format,
            command => index($format, '|') == 0
                        ? \&_notify_stdout
                        : \&_notify_cmd,
        }, $class;
        $self
    }
    sub notify {
        my ($self, $info) = @_;
        &{$self->{command}}($self->{format}, $info);
    }
    sub _notify_stdout {
        my ($format, $info) = @_;
        open my $cmd, sprintf $format
            , $info->{icon} || ''
            , $info->{title};
        print $cmd $info->{text};
        close $cmd;
    }
    sub _notify_cmd {
        my ($format, $info) = @_;
        system sprintf($format, $info->{title}, $info->{text});
    }
}

package TextWriter;
use Encode qw(decode encode);
use Encode::Guess qw(euc-jp shiftjis 7bit-jis);
{
    sub new {
        my ($class, $opts) = @_;
        my $self = bless {
            writer   => {},
            encoding => $opts->{encoding},
            verbose  => $opts->{verbose},
            nlength  => $opts->{nlength} || 40,
        }, $class;
        $self
    }
    sub writeText {
        my ($self, $text, $header) = @_;
        return unless $text;

        my $guess = guess_encoding($text);
        my $text_encoding = ref $guess
            ? $guess->name
            : ($guess =~ /([\w-]+)$/o)[0]; # accept first suspects
        my $raw_text = $text;
        $text = encode($self->{encoding}, decode($text_encoding, $text));

        my $writer = $self->_get_writer($header->{type});
        $writer->write($text);
        if ($self->{verbose} ge 2) {
            printf "[%s] encoding: %s -> %s\n"
                , ref $writer, $text_encoding, $self->{encoding};
            print "$text\n" if ref $writer ne 'Writer';
        }
        $writer->notify({
            title => sprintf('(%s) %s', length($text), ref $writer),
            text  => substr($raw_text, 0, $self->{nlength}),
        });
    }
    sub _get_writer {
        my $self = shift;
        my $type = shift || 'clipboard';
        $self->{writer}->{$type} ||= WriterFactory->create($type);
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
        my $writer = TextWriter->new({
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
            $writer->writeText($text, \%header);
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
