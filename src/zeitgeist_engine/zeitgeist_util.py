import datetime
import os
import urllib
import sys	   # for ImplementMe
import inspect # for ImplementMe
import gobject
import gtk
import gnome.ui
import gnomevfs
import gconf
from gettext import gettext as _
import tempfile, shutil
import subprocess

class FileMonitor(gobject.GObject):
	'''
	A simple wrapper around Gnome VFS file monitors.  Emits created, deleted,
	and changed events.  Incoming events are queued, with the latest event
	cancelling prior undelivered events.
	'''
	
	__gsignals__ = {
		"event" : (gobject.SIGNAL_RUN_LAST, gobject.TYPE_NONE,
				   (gobject.TYPE_STRING, gobject.TYPE_INT)),
		"created" : (gobject.SIGNAL_RUN_LAST, gobject.TYPE_NONE, (gobject.TYPE_STRING,)),
		"deleted" : (gobject.SIGNAL_RUN_LAST, gobject.TYPE_NONE, (gobject.TYPE_STRING,)),
		"changed" : (gobject.SIGNAL_RUN_LAST, gobject.TYPE_NONE, (gobject.TYPE_STRING,))
	}

	def __init__(self, path):
		gobject.GObject.__init__(self)

		if os.path.isabs(path):
			self.path = "file://" + path
		else:
			self.path = path
		try:
			self.type = gnomevfs.get_file_info(path).type
			print "got it"
		except gnomevfs.Error:
			self.type = gnomevfs.MONITOR_FILE
			print "did not get it"

		self.monitor = None
		self.pending_timeouts = {}

	def open(self):
		if not self.monitor:
			if self.type == gnomevfs.FILE_TYPE_DIRECTORY:
				monitor_type = gnomevfs.MONITOR_DIRECTORY
			else:
				monitor_type = gnomevfs.MONITOR_FILE
			self.monitor = gnomevfs.monitor_add(self.path, monitor_type, self._queue_event)
		del monitor_type
		print"open"

	def _clear_timeout(self, info_uri):
		try:
			gobject.source_remove(self.pending_timeouts[info_uri])
		   # delself.pending_timeouts[info_uri]
		except KeyError:
			pass
		del info_uri

	def _queue_event(self, monitor_uri, info_uri, event):
		print "queue event"
		self._clear_timeout(info_uri)
		self.pending_timeouts[info_uri] = \
			gobject.timeout_add(250, self._timeout_cb, monitor_uri, info_uri, event)
		del monitor_uri, info_uri, event

	def queue_changed(self, info_uri):
		print "queue changed"
		self._queue_event(self.path, info_uri, gnomevfs.MONITOR_EVENT_CHANGED)
		del info_uri
		
	def close(self):
		gnomevfs.monitor_cancel(self.monitor)
		self.monitor = None

	def _timeout_cb(self, monitor_uri, info_uri, event):
		if event in (gnomevfs.MONITOR_EVENT_METADATA_CHANGED, gnomevfs.MONITOR_EVENT_CHANGED):
			self.emit("changed", info_uri)
			print "changed "+self.path
		elif event == gnomevfs.MONITOR_EVENT_CREATED:
			self.emit("created", info_uri)
			print "created "+self.path
		elif event == gnomevfs.MONITOR_EVENT_DELETED:
			self.emit("deleted", info_uri)
			print "deleted "+self.path
		elif event == gnomevfs.MONITOR_EVENT_STOPEXECUTING	:
			#self.emit("deleted", info_uri)
			print "closed "+self.path
		self.emit("event", info_uri, event)

		self._clear_timeout(info_uri)
		del monitor_uri, info_uri, event
		return False

class IconFactory():
	'''
	Icon lookup swiss-army knife (from menutreemodel.py)
	'''
	
	def __init__(self):
		self.icon_dict={}
	
	def load_icon_from_path(self, icon_path, icon_size=None):
		try:
			if icon_size:
				pic = gtk.gdk.pixbuf_new_from_file_at_size(icon_path,  int(icon_size), int(icon_size))
				return pic
			else:
				pic =  gtk.gdk.pixbuf_new_from_file(icon_path)
				return pic
		except:
			pass
		return None
	
	def load_icon_from_data_dirs(self, icon_value, icon_size=None):
		data_dirs = None
		if os.environ.has_key("XDG_DATA_DIRS"):
			data_dirs = os.environ["XDG_DATA_DIRS"]
		if not data_dirs:
			data_dirs = "/usr/local/share/:/usr/share/"

		for data_dir in data_dirs.split(":"):
			retval = self.load_icon_from_path(os.path.join(data_dir, "pixmaps", icon_value),
											  icon_size)
			if retval:
				return retval
			
			retval = self.load_icon_from_path(os.path.join(data_dir, "icons", icon_value),
											  icon_size)
			if retval:
				return retval
		return None

	def transparentize(self, pixbuf, percent):
		pixbuf = pixbuf.add_alpha(False, '0', '0', '0')
	        for row in pixbuf.get_pixels_array():
        	    for pix in row:
               		 pix[3] = min(int(pix[3]), 255 - (percent * 0.01 * 255))
       		return pixbuf

	def greyscale(self, pixbuf):
		pixbuf = pixbuf.copy()
	        for row in pixbuf.get_pixels_array():
	            for pix in row:
	                pix[0] = pix[1] = pix[2] = (int(pix[0]) + int(pix[1]) + int(pix[2])) / 3
		return pixbuf


	def load_icon(self, icon_value, icon_size, force_size=True):
		if self.icon_dict.get(icon_value) == None:
			try:
				if isinstance(icon_value, gtk.gdk.Pixbuf):
					return icon_value
				
				if os.path.isabs(icon_value):
					icon = self.load_icon_from_path(icon_value, icon_size)
					if icon:
						return icon
					icon_name = os.path.basename(icon_value)
				else:
					icon_name = icon_value
				
				if icon_name.endswith(".png"):
					icon_name = icon_name[:-len(".png")]
				elif icon_name.endswith(".xpm"):
					icon_name = icon_name[:-len(".xpm")]
				elif icon_name.endswith(".svg"):
					icon_name = icon_name[:-len(".svg")]
				
				icon = None
				info = icon_theme.lookup_icon(icon_name, icon_size, gtk.ICON_LOOKUP_USE_BUILTIN)
				if info:
					if icon_name.startswith("gtk-"):
						icon = info.load_icon()
					elif info.get_filename():
						icon = self.load_icon_from_path(info.get_filename(), icon_size)
				else:
					icon = self.load_icon_from_data_dirs(icon_value, icon_size) 
	
				self.icon_dict[icon_value] = icon
				return icon
			except:
				self.icon_dict[icon_value] = None
				return None
		else:
			return self.icon_dict[icon_value]

	def load_image(self, icon_value, icon_size, force_size = True):
		pixbuf = self.load_icon(icon_value, icon_size, force_size)
		img = gtk.Image()
		img.set_from_pixbuf(pixbuf)
		del pixbuf
		img.show()
		return img

	def make_icon_frame(self, thumb, icon_size = None, blend = False):
		border = 1

		mythumb = gtk.gdk.Pixbuf(thumb.get_colorspace(),
								 True,
								 thumb.get_bits_per_sample(),
								 thumb.get_width(),
								 thumb.get_height())
		mythumb.fill(0x00000080) # black, 50% transparent
		if blend:
			thumb.composite(mythumb, 0, 0,
							thumb.get_width(), thumb.get_height(),
							0, 0,
							1.0, 1.0,
							gtk.gdk.INTERP_NEAREST,
							128)
		thumb.copy_area(border, border,
						thumb.get_width() - (border * 2), thumb.get_height() - (border * 2),
						mythumb,
						border, border)
		return mythumb

class Thumbnailer:
	def __init__(self):
		self.icon_dict={}

	def get_icon(self, uri, mimetype, icon_size, timestamp = 0):
		
		if self.icon_dict.get(uri) == None:
			cached_icon = self._lookup_or_make_thumb(uri,mimetype, icon_size, timestamp)
			self.icon_dict[uri]=cached_icon
		
		return self.icon_dict[uri]

	def _lookup_or_make_thumb(self, uri, mimetype, icon_size, timestamp):
		icon_name, icon_type = \
				   gnome.ui.icon_lookup(icon_theme, thumb_factory, uri, mimetype, 0)
		try:
			if icon_type == gnome.ui.ICON_LOOKUP_RESULT_FLAGS_THUMBNAIL or \
				   thumb_factory.has_valid_failed_thumbnail(uri,int(timestamp)):
				# Use existing thumbnail
				thumb = icon_factory.load_icon(icon_name, icon_size)
			elif self._is_local_uri(uri):
				# Generate a thumbnail for local files only
				thumb = thumb_factory.generate_thumbnail(uri, mimetype)
				thumb_factory.save_thumbnail(thumb, uri, timestamp)

			if thumb:
				thumb = icon_factory.make_icon_frame(thumb, icon_size)
				return thumb
			
		except:
			pass

		return icon_factory.load_icon(icon_name, icon_size)

	def _is_local_uri(self, uri):
		# NOTE: gnomevfs.URI.is_local seems to hang for some URIs (e.g. ssh
		#		or http).  So look in a list of local schemes which comes
		#		directly from gnome_vfs_uri_is_local_scheme.
		scheme, path = urllib.splittype(self.get_uri() or "")
		return not scheme or scheme in ("file", "help", "ghelp", "gnome-help", "trash",
										"man", "info", "hardware", "search", "pipe",
										"gnome-trash")

class DiffFactory:
	def __init__(self):
		pass
	
	def create_diff(self,uri1,content):
		fd, path = tempfile.mkstemp()
		os.write(fd, content)
		diff =	os.popen("diff -u "+path+" "+uri1.replace("file://","",1)).read()
		os.close(fd)
		os.remove(path)
		return diff
		
	def restore_file(self,item):
		fd1, orginalfile = tempfile.mkstemp()
		fd2, patch = tempfile.mkstemp()
		
		os.write(fd1, item.original_source)
		os.write(fd2, item.diff)
		
		os.close(fd1)
		os.close(fd2)
		
		os.system("patch %s < %s" % (orginalfile, patch))
		return orginalfile
	
class IconCollection:
	def __init__(self):
		self.dict = {}
	
	def clear(self):
		self.dict.clear()

class GConfBridge(gobject.GObject):
    DEFAULTS = {
        'compress_empty_days'   : True, 
        'show_note_button'      : True,
        'show_file_button'      : True
    }

    ZEITGEIST_PREFIX = "/apps/zeitgeist/"

    __gsignals__ = {
        'changed' : (gobject.SIGNAL_RUN_LAST | gobject.SIGNAL_DETAILED, gobject.TYPE_NONE, ()),
    }

    def __init__(self, prefix = None):
        gobject.GObject.__init__(self)

        if not prefix:
            prefix = self.ZEITGEIST_PREFIX
        if prefix[-1] != "/":
            prefix = prefix + "/"
        self.prefix = prefix
        
        self.gconf_client = gconf.client_get_default()
        self.gconf_client.add_dir(prefix[:-1], gconf.CLIENT_PRELOAD_RECURSIVE)

        self.notify_keys = { }

    def connect(self, detailed_signal, handler, *args):
        # Ensure we are watching the GConf key
        if detailed_signal.startswith("changed::"):
            key = detailed_signal[len("changed::"):]
            if not key.startswith(self.prefix):
                key = self.prefix + key
            if key not in self.notify_keys:
                self.notify_keys[key] = self.gconf_client.notify_add(key, self._key_changed)

        return gobject.GObject.connect(self, detailed_signal, handler, *args)

    def get(self, key, default=None):
        if not default:
            if key in self.DEFAULTS:
                default = self.DEFAULTS[key]
                vtype = type(default)
            else:
                assert "Unknown GConf key '%s', and no default value" % key

        vtype = type(default)
        if vtype not in (bool, str, int):
            assert "Invalid GConf key type '%s'" % vtype

        if not key.startswith(self.prefix):
            key = self.prefix + key

        value = self.gconf_client.get(key)
        if not value:
            self.set(key, default)
            return default

        if vtype is bool:
            return value.get_bool()
        elif vtype is str:
            return value.get_string()
        elif vtype is int:
            return value.get_int()
        else:
            return value

    def set(self, key, value):
        vtype = type(value)
        if vtype not in (bool, str, int):
            assert "Invalid GConf key type '%s'" % vtype

        if not key.startswith(self.prefix):
            key = self.prefix + key

        if vtype is bool:
            self.gconf_client.set_bool(key, value)
        elif vtype is str:
            self.gconf_client.set_string(key, value)
        elif vtype is int:
            self.gconf_client.set_int(key, value)

    def _key_changed(self, client, cnxn_id, entry, data=None):
        if entry.key.startswith(self.prefix):
            key = entry.key[len(self.prefix):]
        else:
            key = entry.key
        detailed_signal = "changed::%s" % key
        self.emit(detailed_signal)


class ZeitgeistTrayIcon(gtk.StatusIcon):
	
	def __init__(self):
		gtk.StatusIcon.__init__(self)
		self.set_from_file("data/gnome-zeitgeist.png")
		self.set_visible(True)
		
		menu = gtk.Menu()
		
		self.journal_proc = None
		
		menuItem = gtk.ImageMenuItem(gtk.STOCK_HOME)
		menuItem.set_name("Open Journal")
		menu.append(menuItem)
		menuItem.connect('activate', self.open_journal)
		
		menuItem = gtk.ImageMenuItem(gtk.STOCK_PREFERENCES)
		menu.append(menuItem)
		menuItem.connect('activate', self.open_about)
		
		
		menuItem = gtk.ImageMenuItem(gtk.STOCK_ABOUT)
		menu.append(menuItem)
		menuItem.connect('activate', self.open_about)
		
		menuItem = gtk.ImageMenuItem(gtk.STOCK_QUIT)
		menu.append(menuItem)
		 
		self.set_tooltip("Zeitgeist")
		self.connect('popup-menu', self.popup_menu_cb, menu)

	def open_journal(self,widget):
		if self.journal_proc == None or not self.journal_proc.poll() == None:
			self.journal_proc = subprocess.Popen("sh zeitgeist.sh",shell=True)
			
	def open_about(self,widget):
		about.visible=False
		about._toggle_()
				
 	def popup_menu_cb(self,widget, button, time, data = None):
 		if button == 3:
 			if data:
 				data.show_all()
                data.popup(None, None, None, 3, time)

class AboutWindow(gtk.Window):
	def __init__(self):
		gtk.Window.__init__(self)
		# Window
		self.set_title("About Gnome Zeitgeist")
		self.set_resizable(False)
		self.set_size_request(400,320)
		self.connect("destroy", self._toggle_)
		self.set_icon_name(gtk.STOCK_ABOUT)
		self.hide_all()
		self.visible=True
		self.label = gtk.Label()
		self.label.set_markup(self._get_about())
		self.add(self.label)
		
	def _toggle_(self,widget=None):
		if self.visible:
			self.hide_all()
			self.visible=False
		else:
			self.show_all()
			self.label.show_all()
			self.visible=True
			
	def _get_about(self):
		title = "<span size='large' color='blue'>%s</span>" %"GNOME Zeitgeist"
		comment = "Gnome Zeitgeist is a tool for easily browsing and finding files on your computer"
		copyright = "<span size='small' color='blue'>%s</span>"%"Copyright  2009 GNOME Zeitgeist Developers"
		page="http://zeitgeist.geekyogre.com"
		
		about = title +"\n"+"\n"+comment+"\n"+"\n"+copyright+"\n"+"\n"+page
		return about
	

about = AboutWindow()
difffactory=DiffFactory()
icon_factory = IconFactory()
thumbnailer = Thumbnailer()
icon_theme = gtk.icon_theme_get_default()
thumb_factory = gnome.ui.ThumbnailFactory("normal")
iconcollection = IconCollection()
gconf_bridge = GConfBridge()
