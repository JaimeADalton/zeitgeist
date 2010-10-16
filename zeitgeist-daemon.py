#! /usr/bin/env python
# -.- coding: utf-8 -.-

# Zeitgeist
#
# Copyright © 2009 Siegfried-Angel Gevatter Pujals <rainct@ubuntu.com>
# Copyright © 2010 Markus Korn <thekorn@gmx.de>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import sys
import os
import gobject
import dbus.mainloop.glib
import gettext
import logging
import optparse
import signal
from subprocess import Popen, PIPE

# Make sure we can find the private _zeitgeist namespace
from zeitgeist import _config
_config.setup_path()

# Make sure we can load user extensions, and that they take priority over
# system level extensions
from _zeitgeist.engine import constants
sys.path.insert(0, constants.USER_EXTENSION_PATH)

gettext.install("zeitgeist", _config.localedir, unicode=True)

class Options(optparse.Option):
	TYPES = optparse.Option.TYPES + ("log_levels",)
	TYPE_CHECKER = optparse.Option.TYPE_CHECKER.copy()
	log_levels = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")

	def check_loglevel(option, opt, value):
		value = value.upper()
		if value in Options.log_levels:
			return value
		raise optparse.OptionValueError(
			"option %s: invalid value: %s" % (opt, value))
	TYPE_CHECKER["log_levels"] = check_loglevel


def which(executable):
	""" helper to get the complete path to an executable """
	p = Popen(["which", str(executable)], stderr=PIPE, stdout=PIPE)
	p.wait()
	return p.stdout.read().strip() or None

def parse_commandline():
	parser = optparse.OptionParser(version = _config.VERSION, option_class=Options)
	parser.add_option(
		"-r", "--replace",
		action="store_true", default=False, dest="replace",
		help=_("if another Zeitgeist instance is already running, replace it"))
	parser.add_option(
		"--no-datahub", "--no-passive-loggers",
		action="store_false", default=True, dest="start_datahub",
		help=_("do not start zeitgeist-datahub automatically"))
	parser.add_option(
		"--log-level",
		action="store", type="log_levels", default="DEBUG", dest="log_level",
		help=_("how much information should be printed; possible values:") + \
			" %s" % ', '.join(Options.log_levels))
	parser.add_option(
		"--quit",
		action="store_true", default=False, dest="quit",
		help=_("if another Zeitgeist instance is already running, replace it"))
	parser.add_option(
		"--shell-completion",
		action="store_true", default=False, dest="shell_completion",
		help=optparse.SUPPRESS_HELP)
	return parser

def do_shell_completion(parser):
	options = set()
	for option in (str(option) for option in parser.option_list):
		options.update(option.split("/"))
	print ' '.join(options)
	return 0

def setup_interface():
	from _zeitgeist.engine.remote import RemoteInterface
	dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
	mainloop = gobject.MainLoop()
	return mainloop, RemoteInterface(mainloop = mainloop)

def start_datahub():
	DATAHUB = "zeitgeist-datahub"
	# hide all output of the datahub for now,
	# in the future we might want to be more verbose here to make
	# debugging easier in case sth. goes wrong with the datahub
	devnull = open(os.devnull, "w")
	try:
		# we assume to find the datahub somewhere in PATH
		p = Popen(DATAHUB, stdin=devnull, stdout=devnull, stderr=devnull)
	except OSError:
		logging.warning("Unable to start the datahub, no binary found")
	else:
		# TODO: delayed check if the datahub is still running after some time
		#  and not failed because of some error
		# tell the user which datahub we are running
		logging.debug("Running datahub (%s) with PID=%i" %(which(DATAHUB), p.pid))

def setup_handle_sighup(interface):
	def handle_sighup(signum, frame):
		"""We are using the SIGHUP signal to shutdown zeitgeist in a clean way"""
		logging.info("got SIGHUP signal, shutting down zeitgeist interface")
		interface.Quit()
	return handle_sighup
	
if __name__ == "__main__":
	
	parser = parse_commandline()
	
	_config.options, _config.arguments = parser.parse_args()
	if _config.options.shell_completion:
		sys.exit(do_shell_completion(parser))
	
	logging.basicConfig(level=getattr(logging, _config.options.log_level))
	
	logging.info("Setup RemoteInterface")
	try:
		mainloop, interface = setup_interface()
	except RuntimeError, e:
		logging.exception("Failed to setup the RemoteInterface")
		sys.exit(1)
	
	if _config.options.start_datahub:
		logging.info("Trying to start the datahub")
		start_datahub()
	
	logging.info("Connect to SIGHUB signal")
	signal.signal(signal.SIGHUP, setup_handle_sighup(interface))
	
	logging.info("Starting Zeitgeist service...")
	mainloop.run()
