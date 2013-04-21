"""Account manipulation - $Id: account.py,v 1.9 2008-12-11 16:45:32 cvs Exp $
"""

# TODO:
# * Specify account removal by prepending accounts with "-" - means the
#   account should be removed from ALL servers (as people leave).
# * Option to fix up file perms as we change uid/gid - either just home
#   dir, or all local file trees
# * Have configure accept the changeid (and new fixperms) option.

from cfbuild import *
import string


class Service(BasicService):
    "OS account manipulationAgent"

    names = ('account', )

    parms = RecordParm(make_map(
	passwdfile = StringParm(),	# Master passwd file
	groupfile = StringParm(),	# Master group file

	# Ranges to use when auto-allocating IDs.
	uid_range = StringParm(default="1000:1999"),
	gid_range = StringParm(default="1000:1999"),

	# Always add group of same name when adding user (if it exists).
	# Handy if you follow the policy that every user gets a matching
	# group (like redhat linux does)
	matching_groups = BooleanParm(default=0),

	# If a user account has a home director matching one of the patterns
	# specified (argument is a space-separated list of glob patterns)
	# then make sure the directory exists and is owned by the user:group
	# - mode is as specified.
	make_homes_matching = StringParm(default=""),
	make_homes_mode = StringParm(default=""),
	))

    hostparms = RecordParm(repeatable=1, fields=make_map(
        user = StringParm(),		# Username to add, or +groupname to
					# add all users in a group
        group = StringParm(),		# Groupname to add
	))

    def assemble(self):
	# Install runtime script
	self.copy("configure.pl")

	if not re.match("^\d+:\d+$", self.args.uid_range):
	    self.fail("bad uid_range: "+self.args.uid_range)
	if not re.match("^\d+:\d+$", self.args.gid_range):
	    self.fail("bad gid_range: "+self.args.gid_range)

	self.auto_sitevars(
		users="",
		groups="",
		)

	# Load master group from file - save hash of all defined
	# names for later validation
	groupflag = {}
	gidflag = {}
	content = ""
	if self.args.groupfile:
	    content = read_file(self.args.groupfile)
	    for line in content.split("\n"):
		line = line.rstrip()
		# Skip empty lines and comments
		if len(line) == 0 or line.startswith("#"):
		    continue
		cols = line.split(":")
		(name, x, gid) = cols[0:3]
		remove=0
		if name.startswith("-"):
		    # This is a negative account definition (account to be
		    # removed.
		    name = name[1:]
		    remove = 1

		# Simple correctness checks
		if len(cols) != 4:
		    self.fail("group %s has %d fields, should be 4" % (
			    name, len(cols)))
		if groupflag.has_key(name):
		    self.fail("duplicate groupname: "+name)
		if not remove:
		    if gidflag.has_key(gid):
			self.fail("duplicate groupid: "+gid)
		    gidflag[gid] = 1
		    groupflag[name] = 1
	self.add_file("group", content)

	# Load master user (passwd) from file - save hash of all defined
	# names for later validation
	userflag = {}
	uidflag = {}
	content = ""
	if self.args.passwdfile:
	    content = read_file(self.args.passwdfile)
	    for line in content.split("\n"):
		line = line.rstrip()
		# Skip empty lines and comments
		if len(line) == 0 or line.startswith("#"):
		    continue
		cols = line.split(":")
		name, x, uid, gid = cols[0:4]
		remove=0
		if name.startswith("-"):
		    # This is a negative account definition (account to be
		    # removed.
		    name = name[1:]
		    remove = 1

		# Simple correctness checks
		if len(cols) != 7:
		    self.fail("user %s has %d fields, should be 7" % (
			    name, len(cols)))
		if userflag.has_key(name):
		    self.fail("duplicate username: "+name)
		if not remove:
		    if uidflag.has_key(uid):
			self.fail("duplicate userid: "+uid)
		    uidflag[uid] = 1

		    userflag[name] = 1

		    if not (gidflag.has_key(gid) or groupflag.has_key(gid)):
			self.fail("unknown groupid for user %s: %s"
				% (name, gid))
	self.add_file("passwd", content)

	for host, hargslist in self.host_args.items():
	    hvars = {}

	    host_users = {}
	    host_groups = {}
	    for hargs in hargslist:
		if hargs.user:
		    if hargs.user[0] == "+":
			# Want all users in a group - make sure group is
			# valid.
			if not groupflag.has_key(hargs.user[1:]):
			    self.fail("unknown group: "+hargs.user[1:])
		    elif not userflag.has_key(hargs.user):
			self.fail("unknown user: "+hargs.user)
		    host_users[hargs.user] = 1
		if hargs.group:
		    if not groupflag.has_key(hargs.group):
			self.fail("unknown group: "+hargs.group)
		    host_groups[hargs.group] = 1

	    hvars["users"] = ":".join(host_users.keys())
	    hvars["groups"] = ":".join(host_groups.keys())

	    self.set_hostvars(host, hvars)

