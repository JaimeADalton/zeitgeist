#!/usr/bin/python
# -.- coding: utf-8 -.-

import gobject
import signal
import sys
import os

# Update python path to use local zeitgeist module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from zeitgeist.client import ZeitgeistClient
from zeitgeist import datamodel

import testutils
from testutils import parse_events

class DBusInterfaceReconnection(testutils.RemoteTestCase):
	"""
	This class tests the _DBusInterface class (from the zeitgeist.client
	module) . In particular, it ensures that method calls and signals stay
	working after engine restarts.
	"""

	def testRawMethodCalls(self):
		events = parse_events("test/data/single_event.js")
		ids = self.client._iface.InsertEvents(events)
		self.assertEquals(len(ids), 1)
		found_events = self.client._iface.GetEvents(ids)
		self.assertTrue(found_events)
		template = (["","","","",""],["","","","","","",""],[0])
		found_ids = self.client._iface.FindEventIds(
			(0, 200), [template], datamodel.StorageState.Any,
			10, datamodel.ResultType.MostRecentEvents)
		self.assertEquals(len(found_ids), 1)

	def testMethodCallAfterReconnection(self):
		# Insert an event
		events = parse_events("test/data/single_event.js")
		ids = self.client._iface.InsertEvents(events)
		
		# We can now check for it
		self.assertEquals(len(self.client._iface.GetEvents(ids)), 1)
		
		# Restart the daemon
		self.kill_daemon(signal.SIGHUP)
		self.spawn_daemon()
		
		# Can we still check for it?
		try:
			self.assertEquals(len(self.client._iface.GetEvents(ids)), 1)
		except Exception:
			print "\n==> The first method call after reconnecting failed!"
		
		self.assertEquals(len(self.client._iface.GetEvents(ids)), 1)

	def testSignalReconnection(self):
		mainloop = self.create_mainloop()
		datasource = ["www.example.com/foo", "Name", "Description", []]
		self.client._registry.RegisterDataSource(*datasource)
		
		def cb_enabled(unique_id, enabled):
			mainloop.quit()
		
		def enable_disable():
			self.client._registry.SetDataSourceEnabled(datasource[0], False)
			self.client._registry.SetDataSourceEnabled(datasource[0], True)
		
		self.client._registry.connect('DataSourceEnabled', cb_enabled)
		gobject.idle_add(enable_disable)
		
		# Restart the daemon
		self.kill_daemon(signal.SIGHUP)
		self.spawn_daemon()
		
		mainloop.run()

class EventAndSubjectOverrides(testutils.RemoteTestCase):
	"""
	This class tests the functionality allowing users to override the
	Event and Subject types instantiated by ZeitgeistClient (LP: #799199).
	"""

	class CustomEvent(datamodel.Event):
		pass
	
	class CustomSubject(datamodel.Subject):
		pass

	class CustomNothing(object):
		pass

	def testEventOverrideWhiteBox(self):
		self.assertEqual(self.client._event_type, datamodel.Event)
		self.client.register_event_subclass(self.CustomEvent)
		self.assertEqual(self.client._event_type, self.CustomEvent)

	def testSubjectOverrideWhiteBox(self):
		self.assertEqual(self.client._event_type._subject_type, datamodel.Subject)
		self.client.register_subject_subclass(self.CustomSubject)
		self.assertEqual(self.client._event_type._subject_type, self.CustomSubject)

	def testEventAndSubjectOverrideWhiteBox(self):
		self.client.register_event_subclass(self.CustomEvent)
		self.client.register_subject_subclass(self.CustomSubject)
		self.assertTrue(issubclass(self.client._event_type, self.CustomEvent))
		self.assertEqual(self.client._event_type._subject_type, self.CustomSubject)

	def testBadOverride(self):
		self.assertRaises(TypeError, lambda:
			self.client.register_event_subclass(self.CustomNothing))
		self.assertRaises(TypeError, lambda:
			self.client.register_subject_subclass(self.CustomNothing))

	def testEventAndSubjectOverrideBlackBox(self):
		self.client.register_event_subclass(self.CustomEvent)
		self.client.register_subject_subclass(self.CustomSubject)
		self.insertEventsAndWait(parse_events("test/data/single_event.js"))
		result = self.findEventsForValuesAndWait()
		self.assertTrue(len(result[0].subjects) >= 1)
		self.assertTrue(isinstance(result[0], self.CustomEvent))
		self.assertTrue(isinstance(result[0].subjects[0], self.CustomSubject))

	def testMonitorOverrideBlackBox(self):
		self.client.register_event_subclass(self.CustomEvent)
		self.client.register_subject_subclass(self.CustomSubject)
		mainloop = self.create_mainloop()
		
		def notify_insert_handler(time_range, events):
			self.assertTrue(len(events[0].subjects) >= 1)
			self.assertTrue(isinstance(events[0], self.CustomEvent))
			self.assertTrue(
				isinstance(events[0].subjects[0], self.CustomSubject))
			mainloop.quit()
		
		self.client.install_monitor(datamodel.TimeRange.always(), [],
			notify_insert_handler, notify_insert_handler)
		self.client.insert_events(parse_events("test/data/single_event.js"))
		mainloop.run()
