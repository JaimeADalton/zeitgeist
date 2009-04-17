import dbus
import dbus.service
import dbus.mainloop.glib
import gobject
from gettext import ngettext, gettext as _
import gtk
import time

from zeitgeist_engine.zeitgeist_datasink import datasink
from zeitgeist_shared.zeitgeist_shared import *
from zeitgeist_engine.zeitgeist_util import ZeitgeistTrayIcon

class RemoteInterface(dbus.service.Object):
	
	# Initialization
	
	def __init__(self):
		bus_name = dbus.service.BusName("org.gnome.Zeitgeist", dbus.SessionBus())
		dbus.service.Object.__init__(self, bus_name, "/org/gnome/zeitgeist")
	
	# Reading stuff
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="iis", out_signature="a"+sig_plain_data)
	def get_items(self, min_timestamp, max_timestamp, tags):
		items = []
		for item in datasink.get_items(min_timestamp, max_timestamp, tags):
			items.append(item)
		return items
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="s", out_signature="a"+sig_plain_data)
	def get_items_for_tag(self, tag):
		items = []
		for item in datasink.get_items_for_tag(tag):
			items.append(item)
		return items
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="siis", out_signature="a"+sig_plain_data)
	def get_items_with_mimetype(self, mimetype, min_timestamp, max_timestamp, tags):
		items = []
		for item in datasink.get_items_with_mimetype(mimetype, min_timestamp, max_timestamp, tags):
			items.append(item)
		return items
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="", out_signature="a"+sig_plain_data)
	def get_bookmarks(self):
		items = []
		for item in datasink.get_bookmarks():
			items.append(item)
		return items
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="iii", out_signature="as")
	def get_most_used_tags(self, amount, min_timestamp, max_timestamp):
		return list(datasink.get_most_used_tags(amount,
			min_timestamp, max_timestamp))

	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="iii", out_signature="as")
	def get_recent_used_tags(self, amount, min_timestamp, max_timestamp):
		return list(datasink.get_recent_used_tags(amount,
			min_timestamp, max_timestamp))
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="s", out_signature="a"+sig_plain_data)
	def get_related_items(self, item_uri):
		items = []
		for item in datasink.get_related_items(item_uri):
			items.append(item)
		return items
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="s", out_signature="a"+sig_plain_data)
	def get_items_related_by_tags(self, item_uri):
		items = []
		t1 = time.time()
		for item in datasink.get_items_related_by_tags(item_uri):
			items.append(item)
		t2 = time.time()
		print "##########> time to fetch data from DB: "+ str(t2-t1)
		return items
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="", out_signature="a"+sig_plain_dataprovider)
	def get_sources_list(self):
		sources = []
		for source in datasink.get_sources():
			sources.append(plainify_dataprovider(source))
		return sources
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="s", out_signature="(uu)")
	def get_timestamps_for_tag(self, tag):
		return datasink.get_timestamps_for_tag(tag)
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="", out_signature="a"+sig_plain_data)
	def get_bookmarks(self):
		bookmarks = []
		for bookmark in datasink.get_bookmarks():
			bookmarks.append(bookmark)
		return bookmarks
	
	# Writing stuff
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature=sig_plain_data, out_signature="")
	def insert_item(self, item_list):
		datasink.insert_item(dictify_data(item_list))
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature=sig_plain_data, out_signature="")
	def update_item(self, item_list):
		datasink.update_item(dictify_data(item_list))
	
	@dbus.service.method("org.gnome.Zeitgeist",
						in_signature="s", out_signature="")
	def delete_item(self, item_uri):
		datasink.delete_item(item_uri)
	
	# Signals and signal emitters
	
	@dbus.service.signal("org.gnome.Zeitgeist")
	def signal_updated(self):
		# We forward the "reload" signal, but only if something changed.
		print "Emitted \"updated\" signal." # pass
	
	@dbus.service.method("org.gnome.Zeitgeist")
	def emit_signal_updated(self):
		self.signal_updated()


if __name__ == "__main__":
	
	dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
	object = RemoteInterface()
	datasink.reload_callbacks.append(object.signal_updated)

	trayicon = ZeitgeistTrayIcon()
	
	mainloop = gobject.MainLoop()
	print _("Running Zeitgeist service.")
	mainloop.run()
