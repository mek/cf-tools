"""apt/dpkg package management
"""

from cfbuild import *


class Service(PackageService):
    """apt/dpkg package management service
    """

    names = ("aptpkg", )
    required_services = ( "supert", )

    parms = RecordParm(make_map(
            ))

    hostparms = RecordParm(repeatable=1, fields=make_map(
            package = StringParm(),
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
        self.auto_sitevars(required="", reltag="",environ="debian")
	self.copy("configure.pl")

        for host, hargslist in self.host_args.items():
            nonprod = supert.get_members("dev") + supert.get_members("stage") \
                      + supert.get_members("work")
            if host in nonprod:
                default_reltag = "dev"
            else:
                default_reltag = "prod"

            hostvars = {}
            pkgs = []
            for hargs in hargslist:
                for key, val in hargs.__dict__.items():
                    if key == "package" and val is not None:
                        pkgs.append(hargs.package)
                    elif val is not None:
                        if hostvars.has_key(key):
                            self.fail("attempt to reset %s for host %s"
                                % (key, host))
                        hostvars[key] = val

            if not hostvars.has_key("reltag"):
                hostvars['reltag'] = default_reltag
            hostvars["required"] = ":".join(pkgs)
            self.set_hostvars(host, hostvars)

        self.cf.copydir("aptpkg","aptpkg", exclude=('CVS', '.svn'))

