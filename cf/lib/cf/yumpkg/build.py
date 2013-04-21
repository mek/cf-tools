"""Yum package management - $Id: yumpkg.py,v 1.12 2008-09-22 12:28:40 cvs Exp $
"""

from cfbuild import *


class Service(PackageService):
    """Yum package management service

    Add a package:
    <yumpkg package="name"/>
    Remove a package:
    <yumpkg package="-name"/>
    Add a group:
    <yumpkg group="group name"/>
    <yumpkg package="@group name"/>
    Remove a group:
    <yumpkg group="-group name"/>
    <yumpkg package="-@group name"/>
    """

    names = ("yumpkg", )
    required_services = ( "supert", "account",)

    parms = RecordParm(make_map(
            ))

    hostparms = RecordParm(repeatable=1, fields=make_map(
            package = StringParm(),
            group = StringParm(),
            environ = StringParm(),
            reltag = StringParm(),
            ))

    def init2(self):
        self.args.prefix = ""
        self.host_pkgs = {}

    def attach2(self, host, hargs):
        if hargs.package:
            if not self.host_pkgs.has_key(host):
                self.host_pkgs[host] = []
            self.host_pkgs[host].append(hargs.package)

    def assemble(self):
        supert = self.get_service("supert")
        self.auto_sitevars(required="", reltag="",environ="centos")
	self.copy("configure.pl")

        for host, hargslist in self.host_args.items():
	    default_reltag = "prod"

            hostvars = {}
            pkgs = []
            for hargs in hargslist:
                for key, val in hargs.__dict__.items():
                    if key == "package" and val is not None:
                        pkgs.append(hargs.package)
                    elif key == "group" and val is not None:
                        if hargs.group.startswith('-'):
                            pkgs.append("-@%s" % hargs.group.lstrip('-'))
                        else:
                            pkgs.append("@%s" % hargs.group)
                    elif val is not None:
                        if hostvars.has_key(key):
                            self.fail("attempt to reset %s for host %s"
                                % (key, host))
                        hostvars[key] = val

            if not hostvars.has_key("reltag"):
                hostvars['reltag'] = default_reltag
            hostvars["required"] = ":".join(pkgs)
            self.set_hostvars(host, hostvars)

        # Copy base yum files
        self.cf.copydir("yumpkg","yumpkg", exclude=('CVS', '.svn'))
