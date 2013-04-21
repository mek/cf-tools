# $Id:$
#
# Local account management.

use strict;

my $users = $this_vars->{users} // "";
my $groups = $this_vars->{groups} // "";
my $uid_range = $this_vars->{uid_range} // "1000:1999";
my $gid_range = $this_vars->{gid_range} // "1000:1999";
my $matching_groups = $this_vars->{matching_groups} // 0;
my $make_homes_matching = $this_vars->{make_homes_matching} // 0;
my $make_homes_mode = $this_vars->{make_homes_mode} // "";

my $host = get_host();

my $os_class = getos("class");
my $is_win = (getos() =~ /^win/);
my $need_pwconv = !$is_win;
if ($is_win) {
    require Win32::NetAdmin;
}

# Convert home globs to regular expressions.
my @make_home_regex = ();
foreach my $globstr (split(" ", $make_homes_matching)) {
    push(@make_home_regex, glob2pat($globstr));
}

# See if we need to use chpass (BSD)
my $chpass;
my $masterpass = "/etc/master.passwd";
foreach my $path ('/usr/bin/chpass') {
    if (fileinfo($path)->type ne 'NONE') {
	$chpass = $path;
	last;
    }
}


# Available account definitions indexed by username. Each value is a
# /etc/passwd style line.
my %userdef = ();

# List of usernames that should be removed (everywhere).
my @delusers = ();

my $reference_passwd = "$this_dir/passwd";
if (-f $reference_passwd) {
    foreach my $line (split("\n", read_file($reference_passwd))) {
        next if $line =~ /^#/;
        next if $line =~ /^\s*$/;
        my ($name, $rest) = split(":", $line, 2);
        if ($name =~ /^-(.*)/) {
            # Account to be removed
            push(@delusers, $1);
        } else {
            $userdef{$name} = $rest;
        }
    }
}

# Available group definitions indexed by groupname. Each value is a
# /etc/group style line.
my %groupdef = ();

# List of group names that should be removed (everywhere).
my @delgroups = ();

my $reference_group = "$this_dir/group";
if (-f $reference_group) {
    foreach my $line (split("\n", read_file($reference_group))) {
        next if $line =~ /^#/;
        next if $line =~ /^\s*$/;
        my ($name, $rest) = split(":", $line, 2);
        if ($name =~ /^-(.*)/) {
            # Account to be removed
            push(@delgroups, $1);
        } else {
            $groupdef{$name} = $rest;
        }
    }
}


# Make sure local user account exists, and has the correct attributes.

my %user_opts = (
    DIR => \&parse_string,
    HOME => "DIR",
    D => "DIR",
    SHELL => \&parse_string,
    S => "SHELL",
    GID => \&parse_string,
    GROUP => "GID",
    G => "GID",
    UID => \&parse_string,
    U => "UID",
    GCOS => \&parse_string,
    COMMENT => "GCOS",
    C => "GCOS",
    DUPID => \&parse_bool,
    CHANGEID => \&parse_bool,
);

sub adduser {
    my ($o, $name) = get_options(\%user_opts, @_);
    AddUser($name, $o);
}

sub loaduser {
    my ($o, $name) = get_options({}, @_);
    AddDefinedUser($name, $o);
}

sub GetGroupIdFromName ($) {
    my ($gname) = @_;
    my $gid = getgrnam($gname);
    if (!defined $gid) {
	# Dont abort on unknown group if in dry run mode
	# !!! - should be recording dry-run changes so we can check there.
	die "unknown group: $gname\n" if updating();
	$gid = '?';
    }
    return $gid;
}

sub AddUser($;$) {
    my ($name, $optref) = @_;

    # Make copy of options as we will be modifying the copy $o points to
    # (dont modify the copy passed to us).
    my $o = { %{ $optref } };

    # Field defaults
    my %default = (
	PASSWD => "*",
	UID => $uid_range,
	GID => "nobody",
	GCOS => "",
	DIR => "/no/where",
	SHELL => "/no/shell",
    );

    my %old = ();
    if (my @oldcols = getpwnam($name)) {
	# Account exists - use current settings for unspecified fields
	my $i = 0;
	foreach my $key ("NAME","PASSWD","UID","GID",
		"QUOTA","COMMENT","GCOS","DIR","SHELL","EXPIRE") {
	    $old{$key} = @oldcols[$i];
	    $i++;
	}
    }

    # Convert group names to id's (for comparison)
    if (defined $o->{GID} && $o->{GID} !~ /^\d+$/) {
	$o->{GID} = GetGroupIdFromName($o->{GID});
    }

    if ($userdef{$name}) {
	# Have entry in master table for this account - file in fields from
	# there.

	my @cols = split(":", $userdef{$name});
	my $i = 0;
	foreach my $key ("PASSWD","UID","GID","GCOS","DIR","SHELL") {
	    my $val = @cols[$i++];

	    # Convert group name to GID
	    if ($key eq 'GID' && $val !~ /^\d+$/) {
		$val = GetGroupIdFromName($val);
	    }

	    if (defined $o->{$key} && $o->{$key} ne $val) {
		die "can't override master $key for $name\n";
	    }
	    $o->{$key} = $val;
	}
    } elsif (%old) {
	# Account exists - use current settings for unspecified fields
	my $i = 0;
	foreach my $key (keys(%old)) {
	    $o->{$key} = $old{$key} unless defined $o->{$key};
	}
    } else {
	# No current account - use defaults for unspecified fields
	foreach my $key (keys(%default)) {
	    $o->{$key} = $default{$key} unless defined $o->{$key};
	}
    }

    if ($o->{UID} =~ /^~(.*)/) {
	# Soft specification for ID - dont change if account already exists.

	if (defined $old{UID}) {
	    # Account exists - keep current ID.
	    $o->{UID} = $old{UID};
	} else {
	    # Account does not exist - use ID from spec.
	    $o->{UID} = $1;
	}
    } elsif ($o->{UID} =~ /:/) {
	# uid is a range - find an unused one

	my ($min, $max) = split(":", $o->{UID});
	die "bad range ".$o->{UID}."\n" unless $min < $max;
	my $uid = $min;
	while (getpwuid($uid)) {
	    die "no uid available between $min and $max\n" if $uid == $max;
	    $uid++;
	}
	$o->{UID} = $uid;
    } elsif (!$o->{DUPID} && (my $other_name = getpwuid($o->{UID}))) {
	die "can't give $o->{UID} to $name, used by $other_name\n"
		if $other_name ne $name;
    }

    # Convert group names to id's again (in case we used default)
    if ($o->{GID} !~ /^\d+$/) {
	# Gid is not numeric - try lookup by name

	$o->{GID} = GetGroupIdFromName($o->{GID});
    }

    if (defined $old{UID} && $o->{UID} != $old{UID}) {
	# UID is changing

	# Fail unless id changes are allowed.

	die "can't change $name uid from $old{UID} to $o->{UID}\n"
	    unless $o->{CHANGEID};

	if ($o->{IDCHANGES}) {
	    # Want list of all id changes performed.
	    push(@{$o->{IDCHANGES}}, "user:$old{UID}:$o->{UID}");
	}
    }

    my @cols = ($name, $o->{PASSWD}, $o->{UID}, $o->{GID}, $o->{GCOS},
		$o->{DIR}, $o->{SHELL});
    if ($chpass) {
	# Look up master entry for account
	my ($old, $old2) = grep(/^$name:/, split("\n", read_file($masterpass)));
	die "multiple accounts for $name\n" if (defined $old2);

	# Insert the three extra fields from the master password entry.
	my @extra;
	if (defined $old) {
	    @extra = (split(':', $old))[4,5,6];
	} else {
	    # no user found - default extra fields
	    @extra = ('', 0, 0);
	}
	splice(@cols,4,0,@extra);

	# Run chpass if line has changed.
	my $line = join(':', @cols);
	if ($line ne $old) {
	    run($chpass, '-a', $line, $name);
	}
    } else {
	# Assume system-v with shadow passwords
	# Always want password to be 'x' in the passwd file (real passwd is
	# in shadow).
	$cols[1] = 'x';

	my $line = join(':', @cols);
	my $initial = changes();
	setline("/etc/passwd", "^$name:", $line);

	# Sync the shadow file
	if ($need_pwconv) {
	    run('pwconv') if (changes($initial));
	}

	if ($o->{PASSWD} eq "*LK*") {
	    # Want the password locked out (set to invalid string)

	    my $oldpw = $old{PASSWD};
	    debug("$name should have a locked password, currently is $oldpw");
	    if ($oldpw ne "x" && $oldpw ne "NP" && $oldpw !~ /^\*/ && $oldpw !~ /^!!/) {
		# Current (shadow) password is not one of the expected
		# values for a locked account - lock it using the passwd
		# command.

		run("passwd", "-l", $name);
	    }
	}
    }

    foreach my $pattern (@make_home_regex) {
	if ("!$o->{DIR}" =~ /$pattern/) {
	    # Matched pattern that starts with "!" - exclude this directory
	    last;
	}
	if ($o->{DIR} =~ /$pattern/) {
	    # Matched pattern - check this home directory.
	    my @opts = (-user=>$o->{UID}, -group=>$o->{GID});
	    if (length($make_homes_mode)) {
		push(@opts, -mode=>$make_homes_mode);
	    }
	    directory(@opts, $o->{DIR});
	    last;
	}
    }
}

# Make sure specified user does not exist.

sub DeleteUser($) {
    my ($name) = @_;

    if ($chpass) {
	# BSD-style passwd management
	# Look up master entry for account
	my ($old, $old2) = grep(/^$name:/, split("\n", read_file($masterpass)));
	die "multiple accounts for $name\n" if (defined $old2);

	if (defined $old) {
	    run('pw', 'userdel', '-n', $name);
	}
    } else {
	# Assume system-v with shadow passwords

	my $initial = changes();
	deletelines("/etc/passwd", "^$name:");

	# Sync the shadow file
	if ($need_pwconv) {
	    run('pwconv') if (changes($initial));
	}
    }
}

# Make sure local group exists, and has the correct attributes.

my %group_opts = (
    GID => \&parse_string,
    G => "GID",
    MEMBERS => \&parse_string,
    M => "MEMBERS",
    ADD => \&parse_string,
    REMOVE => \&parse_string,
    DUPID => \&parse_bool,
    CHANGEID => \&parse_bool,
);

sub addgroup {
    my ($o, $name) = get_options(\%group_opts, @_);
    AddGroup($name, $o);
}

sub loadgroup {
    my ($o, $name) = get_options({}, @_);
    AddDefinedGroup($name, $o);
}

sub AddGroup($;$) {
    my ($name, $optref) = @_;

    # Make copy of options as we will be modifying the copy $o points to
    # (dont modify the copy passed to us).
    my $o = { %{ $optref } };

    # Field defaults
    my %default = (
	PASSWD => "*",
	GID => $gid_range,
	MEMBERS => "",
    );

    my %old = ();
    if (my @oldcols = getgrnam($name)) {
	# Group exists - get current settings
	my $i = 0;
	foreach my $key ("NAME","PASSWD","GID","MEMBERS") {
	    $old{$key} = @oldcols[$i];
	    $i++;
	}
    }

    if ($groupdef{$name}) {
	my @cols = split(":", $groupdef{$name});
	my $i = 0;
	foreach my $key ("PASSWD","GID","MEMBERS") {
	    my $val = @cols[$i++];
	    if (defined $o->{$key} && $o->{$key} ne $val) {
		die "can't override master $key for $name\n";
	    }
	    $o->{$key} = $val;
	}
    } elsif (%old) {
	# Group exists - use current settings for unspecified fields
	foreach my $key (keys(%old)) {
	    if ($key eq "MEMBERS") {
		if ($is_win && IsLocalSid($old{PASSWD})) {
		    # Group is mapped to a local windows account, get
		    # members from windows group.
		    #
		    # !!! should i lookup win group by sid (in PASSWD
		    # field)?
		    # The name may not match .. but lookup up groups by
		    # SID appears very messy?
		    $old{MEMBERS} = join(",", WinGetMembers($name));
		} else {
		    # Make member list comma separated - no white space
		    # !! is such white space even allowed in group files?
		    $old{MEMBERS} =~ s/[,\s]+/,/g;
		}
	    }
	    $o->{$key} = $old{$key} unless defined $o->{$key};
	}
    } else {
	# No current account - use defaults for unspecified fields
	foreach my $key (keys(%default)) {
	    $o->{$key} = $default{$key} unless defined $o->{$key};
	}
    }

    if ($o->{GID} =~ /^~(.*)/) {
	# Soft specification for ID - dont change if account already exists.

	if (defined $old{GID}) {
	    # Account exists - keep current ID.
	    $o->{GID} = $old{GID};
	} else {
	    # Account does not exist - use ID from spec.
	    $o->{GID} = $1;
	}
    } elsif ($o->{GID} =~ /:/) {
	# gid is a range - find an unused one

	my ($min, $max) = split(":", $o->{GID});
	die "bad range ".$o->{GID}."\n" unless $min < $max;
	my $gid = $min;
	while (getgrgid($gid)) {
	    die "no gid available between $min and $max\n" if $gid == $max;
	    $gid++;
	}
	$o->{GID} = $gid;
    } elsif (!$o->{DUPID} && (my $other_name = getgrgid($o->{GID}))) {
	die "can't give $o->{GID} to $name, used by $other_name\n"
		if $other_name ne $name;
    }

    if (defined $old{GID} && $o->{GID} != $old{GID}) {
	# GID is changing

	# Fail unless id changes are allowed.

	die "can't change $name gid from $old{GID} to $o->{GID}\n"
	    unless $o->{CHANGEID};

	if ($o->{IDCHANGES}) {
	    # Want list of all id changes performed.
	    push(@{$o->{IDCHANGES}}, "group:$old{GID}:$o->{GID}");
	}
    }

    if (defined $o->{REMOVE} || defined $o->{ADD}) {
	# Edit members - add/remove users.

	my %delflags = ();
	foreach my $user (split(',', $o->{REMOVE})) {
	    $delflags{$user} = 1;
	}
	my %addflags = ();
	foreach my $user (split(',', $o->{ADD})) {
	    $addflags{$user} = 1;
	}

	my @newmembers = ();
	foreach my $user (split(',', $o->{MEMBERS})) {
	    push(@newmembers, $user) unless $delflags{$user};
	    delete $addflags{$user};
	}
	push(@newmembers, keys(%addflags));
	$o->{MEMBERS} = join(',', @newmembers);
    }

    if ($is_win && IsLocalSid($o->{PASSWD})) {
	# The group is mapped to a local windows group - update the members
	# in the windows group, not in the /etc/group file.
	WinSetMembers($name, split(',', $o->{MEMBERS}));
	$o->{MEMBERS} = '';
    }

    my $line = join(':', $name, $o->{PASSWD}, $o->{GID}, $o->{MEMBERS});
    setline("/etc/group", "^$name:", $line);
}

# Make sure specified user does not exist.

sub DeleteGroup($) {
    my ($name) = @_;

    deletelines("/etc/group", "^$name:");
}


#----
# Configure the account service.

sub configure {
    my ($o) = get_options({}, @_);

    if ($os_class eq 'cygwin') {
	# Under cygwin - check root account entry.

	my ($junk, $junk, $admin_uid, $admin_gid, $junk, $junk, $junk,
		$admin_home, $admin_shell) = getpwnam("Administrator");
	if (!defined $admin_uid) {
	    die "can't find Administrator in /etc/passwd\n";
	}

	adduser(-uid=>$admin_uid, -gid=>$admin_gid,
		-home=>$admin_home,
		-shell=>$admin_shell,
		-dupid=>1,
		'root',
		);
    }

    SetDefinedAccounts({});
}

#----
# Configure all compiled in accounts with --changeid flag set - return list
# of ids that were changed. List is space-seperated. Each item is a tuple of
# type:old-id:new-id. Type is either "user" or "group".

sub changeids {
    my ($o) = get_options({}, @_);

    my @changes = ();
    my $o = {
	CHANGEID =>1,
	IDCHANGES => \@changes,
    };
    SetDefinedAccounts($o);
    return join(" ", @changes);
}
string_op('changeids');

#----
# Check/fix all compiled in accounts.

sub SetDefinedAccounts($) {
    my ($o) = @_;

    ## Delete obsolete groups and users

    foreach my $group (@delgroups) {
	DeleteGroup($group);
    }
    foreach my $user (@delusers) {
	DeleteUser($user);
    }

    ## Add desired groups

    foreach my $group (split(":", $groups)) {
	AddDefinedGroup($group, $o);
    }

    ## Add desired users.

    foreach my $user (split(":", $users)) {
	if ($user =~ /^\+(.*)/) {
	    # User actually an "+" prefixed groupname - add all users in the
	    # group.
	    my $group = $1;
	    my ($gpass, $gid, $members) = split(":", $groupdef{$group});
	    foreach my $member (split(",", $members)) {
		AddDefinedUser($member, $o);
	    }
	} else {
	    # Normal user name.
	    AddDefinedUser($user, $o);
	}
    }

    # !!! - TODO? remove unknown user/groups from controlled id ranges
}

# Hash of flags tracking users and groups we've added - so we dont waste
# time repeating.
my %user_flag = ();
my %group_flag = ();

# Add named user from master definition list.
sub AddDefinedUser($;$) {
    my ($user, $o) = @_;

    die "unknown user: $user\n" unless defined $userdef{$user};
    if ($matching_groups) {
	# Want group for user installed too

	# If user record specifies a group by name then add it, otherwise
	# try to add group with same name as user.
	my @cols = split(":", $userdef{$user});
	my $group = ($cols[2] =~ /^\d+/) ? $user : $cols[2];

	if (defined $groupdef{$group}) {
	    AddDefinedGroup($group, $o);
	}
    }
    AddUser($user, $o) unless $user_flag{$user};
    $user_flag{$user} = 1;
}

# Add named group from master definition list.
sub AddDefinedGroup($;$) {
    my ($group, $o) = @_;

    die "unknown group: $group\n" unless defined $groupdef{$group};
    AddGroup($group, $o) unless $group_flag{$group};
    $group_flag{$group} = 1;
}

# Generate a random password - make sure it has a good variety of characters
# (so that OS won't reject it).

sub makepass {
    my ($o) = get_options({LENGTH=>\&parse_int}, @_);
    my $length = $o->{LENGTH} || 12;
    my $tries = 100;

    # !!! will this definition work in other locales?
    my @chars = ('a'..'z', 'A'..'Z', '0'..'9',
	    split('', "!@#$%^&*()_+=-`~[]\;,./") );
    my $numchars = scalar(@chars);

    foreach my $try (1..$tries) {
	my $pass = '';
	foreach my $i (1..$length) {
	    $pass .= $chars[int(rand($numchars))];
	}

	# Try again unless we have a sample of each char type.
	if ($pass !~ /\d/
		|| $pass !~ /[a-zA-Z]/
		|| $pass !~ /\W/) {
	    next;
	}

	return $pass;
    }
    die "can't create decent password in $tries attempts\n";
}
string_op('makepass');

#---------
# Private functions

# Determine local machins SID by using cygwin's mkpasswd to get the local
# administrator SID.
# !!! will have trouble if folk decied to rename there local administrator
# account

my $local_machine_sid;
if ($is_win) {
    my $admin_pwd = read_command("mkpasswd -l -u administrator");
    my ($x, $x, $x, $x, $gecos) = split(":", $admin_pwd);
    my @gecos_parts = split(",", $gecos);
    my $sid = $gecos_parts[-1];
    $sid =~ /^(.*)-500$/ or die "cant find SID in $admin_pwd";
    $local_machine_sid = $1;
    debug("local machine SID is $local_machine_sid");
}

# Return true is SID (in string format) corresponds to a local account
# (either built-in or in local machines SID).
sub IsLocalSid($) {
    my ($sid) = @_;
    return 0 unless $sid =~ /^S-1-5-/;
    return 1 unless $sid =~ /^S-1-5-21-(.*)-\d+$/;
    return $sid =~ /^$local_machine_sid-/;
}

sub WinGetMembers($) {
    my ($group) = @_;

    my @members;
    Win32::NetAdmin::LocalGroupGetMembersWithDomain('', $group, \@members)
	    or die "can't get members of $group: $^E\n";
    my @members2 = ();
    foreach my $member (@members) {
	my ($dom, $user) = split(/\\/, $member, 2);
	my ($udom, $usid, $utype);
	Win32::LookupAccountName('', $user, $udom, $usid, $utype);
	if ($dom eq $udom) {
	    push(@members2, $user);
	} else {
	    push(@members2, $member);
	}
	push(@members2, $member);
    }
    return @members2;
}

sub WinSetMembers($@) {
    my ($group, @members) = @_;

    my @old = WinGetMembers($group);
    my %flag = ();
    foreach my $member (@old) {
	$flags{$member} = 1;
    }

    foreach my $member (@members) {
	if (!$flags{$member}) {
	    markchange("adding $member to $group group");
	    if (updating()) {
		Win32::NetAdmin::LocalGroupAddUsers('', $group, $member);
	    }
	}
	$flags{$member} = 2;
    }

    foreach my $member (@old) {
	if ($flags{$member} != 2) {
	    markchange("removing $member from $group group");
	    if (updating()) {
		Win32::NetAdmin::LocalGroupDeleteUsers('', $group, $member);
	    }
	}
    }
}

