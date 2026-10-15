// Oblien native desktop session preparation, copied from its desktop viewer on 2026-09-17.
// Source: https://oblien.com/docs/workspace/desktop (workspace viewer script).
// SHA-256 of the Perl source: 22bf10d28d528c1d4240c11da3f8e6f012ed3ba521069d6ff03c8ea8b3351ac3
// Keep this provider-specific routine together; credentials are supplied only on stdin.
enum DesktopSessionPreparation {
    static let script = #"""
#!/usr/bin/perl
# Prepare the image account's graphical session through its native runtime.
# Credentials arrive on stdin, never in argv or task logs. No UI coordinates.
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Encode qw(encode);
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);

sub output { print encode_json($_[0]), "\n"; }
sub capture {
    my @command = @_;
    open my $pipe, '-|', @command or die "Could not inspect the desktop session\n";
    local $/;
    my $value = <$pipe> // '';
    close $pipe;
    $value =~ s/\s+$//;
    return $value;
}
sub console_user { return capture('/usr/bin/stat', '-f', '%Su', '/dev/console'); }

die "Desktop session preparation requires the native root runtime\n" if $> != 0;
my $input = do { local $/; <STDIN> };
die "Invalid desktop session request\n" if !defined($input) || length($input) > 32768;
my $request = decode_json($input);
my $user = $request->{username} // '';
die "Invalid desktop account\n" if $user !~ /^[a-zA-Z0-9_.-]{1,64}$/;
my $uid = getpwnam($user);
die "Desktop account is unavailable\n" if !defined($uid) || $uid < 500;
my $journal = '/var/db/oblien-desktop-autologin.json';
my $current = console_user();
if ($current eq $user && !-e $journal) { output({ready => JSON::PP::true, existing => JSON::PP::true}); exit 0; }
die "Another desktop session is active\n" if $current ne $user && $current ne 'root' && $current ne 'loginwindow';

# Serialize simultaneous browser connections. An open file lock releases on exit.
sysopen my $lock, '/var/run/oblien-desktop-session.lock', O_CREAT | O_RDWR | O_NOFOLLOW, 0600
    or die "Could not lock desktop session preparation\n";
my @info = stat($lock);
die "Invalid desktop session lock\n" if $info[4] != 0 || ($info[2] & 077) != 0;
my $locked = 0;
for (1 .. 10) {
    if (flock($lock, LOCK_EX | LOCK_NB)) { $locked = 1; last; }
    sleep 1;
}
die "Another connection is preparing this desktop; retry shortly\n" if !$locked;
my $password = $request->{password} // '';
die "Desktop login is not provisioned\n" if $password eq '' || $password =~ /\0/;
my $preferences = '/Library/Preferences/com.apple.loginwindow';
my $changed = 0;
my $temporary;
sub cleanup {
    if ($changed) {
        system('/usr/bin/defaults', 'delete', $preferences, 'autoLoginUser');
        unlink '/etc/kcpassword';
        unlink $journal;
        $changed = 0;
    }
    unlink $temporary if defined($temporary) && -e $temporary;
}
END { cleanup(); }
$SIG{TERM} = $SIG{INT} = sub { die "Desktop session preparation stopped\n"; };

# A VM can be powered off during sign-in. Recover only a credential created by
# this helper, and preserve login settings an administrator changed afterward.
if (-e $journal) {
    sysopen my $record, $journal, O_RDONLY | O_NOFOLLOW or die "Could not inspect pending desktop preparation\n";
    my @record_info = stat($record);
    die "Invalid desktop preparation record\n" if $record_info[4] != 0 || ($record_info[2] & 077) != 0 || $record_info[7] > 4096;
    my $saved = decode_json(do { local $/; <$record> });
    close $record;
    die "Another account has a pending desktop preparation\n" if $saved->{username} ne $user;
    if (-e '/etc/kcpassword') {
        sysopen my $credential, '/etc/kcpassword', O_RDONLY | O_NOFOLLOW or die "Could not inspect pending desktop login\n";
        my @credential_info = stat($credential);
        die "Invalid pending desktop login\n" if $credential_info[4] != 0 || ($credential_info[2] & 077) != 0 || $credential_info[7] > 32768;
        my $bytes = do { local $/; <$credential> };
        close $credential;
        die "Desktop login settings changed; preserve them and sign in normally\n" if sha256_hex($bytes) ne $saved->{credential_sha256};
    }
    my $account = capture('/usr/bin/defaults', 'read', $preferences, 'autoLoginUser');
    die "Desktop login settings changed; preserve them and sign in normally\n" if $account ne '' && $account ne $user;
    $changed = 1;
    cleanup();
}
if (console_user() eq $user) { output({ready => JSON::PP::true, existing => JSON::PP::true}); exit 0; }

# Do not replace a user's existing automatic-login configuration.
my $configured = capture('/usr/bin/defaults', 'read', $preferences);
die "Automatic login is already configured; use the existing login settings\n"
    if $configured =~ /\bautoLoginUser\s*=/ || -e '/etc/kcpassword';
die "Another desktop session became active\n" if console_user() ne 'root';

my @key = (0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f);
my $plain = encode('UTF-8', $password) . "\0";
$plain .= "\0" while length($plain) % 12;
my $encoded = join '', map { chr(ord(substr($plain, $_, 1)) ^ $key[$_ % @key]) } 0 .. length($plain) - 1;
my ($record, $record_name) = tempfile('oblien-desktop-XXXXXX', DIR => '/var/db', UNLINK => 0);
print {$record} encode_json({username => $user, credential_sha256 => sha256_hex($encoded)});
close $record or die "Could not save desktop preparation state\n";
rename $record_name, $journal or die "Could not save desktop preparation state\n";
$changed = 1;
my ($file, $name) = tempfile('oblien-kcpassword-XXXXXX', DIR => '/private/etc', UNLINK => 0);
$temporary = $name;
chmod 0600, $file;
print {$file} $encoded;
close $file or die "Could not prepare desktop login\n";
rename $temporary, '/etc/kcpassword' or die "Could not prepare desktop login\n";
system('/usr/bin/defaults', 'write', $preferences, 'autoLoginUser', '-string', $user) == 0
    or die "Could not prepare desktop login\n";

# Only the initial, root-owned login window is restarted. Never log out a user.
my $pid = capture('/usr/bin/pgrep', '-U', '0', '-x', 'loginwindow');
die "The initial login window is unavailable\n" if $pid !~ /^\d+$/ || console_user() ne 'root';
kill 'TERM', int($pid) or die "Could not start the desktop session\n";
for (1 .. 40) {
    sleep 1;
    if (console_user() eq $user && capture('/usr/bin/pgrep', '-U', "$uid", '-x', 'Finder') ne ''
            && capture('/usr/bin/pgrep', '-U', "$uid", '-x', 'Dock') ne '') {
        cleanup();
        output({ready => JSON::PP::true, existing => JSON::PP::false});
        exit 0;
    }
}
die "The desktop session did not become ready\n";
"""#
}
