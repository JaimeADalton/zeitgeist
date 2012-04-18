/* remote.vala
 *
 * Copyright © 2011 Collabora Ltd.
 *             By Siegfried-Angel Gevatter Pujals <siegfried@gevatter.com>
 * Copyright © 2011 Michal Hruby <michal.mhr@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

namespace Zeitgeist
{
    public struct VersionStruct
    {
        int major;
        int minor;
        int micro;
    }

    [DBus (name = "org.gnome.zeitgeist.Log")]
    public interface RemoteLog : Object
    {

        [DBus (signature = "(xx)")]
        public abstract Variant delete_events (
            uint32[] event_ids,
            BusName sender
        ) throws Error;

        public abstract uint32[] find_event_ids (
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant event_templates,
            uint storage_state, uint num_events, uint result_type,
            BusName sender
        ) throws Error;

        [DBus (signature = "a(asaasay)")]
        public abstract Variant find_events (
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant event_templates,
            uint storage_state, uint num_events, uint result_type,
            BusName sender
        ) throws Error;

        public abstract string[] find_related_uris (
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant event_templates,
            [DBus (signature = "a(asaasay)")] Variant result_event_templates,
            uint storage_state, uint num_events, uint result_type,
            BusName sender
        ) throws Error;

        [DBus (signature = "a(asaasay)")]
        public abstract Variant get_events (
            uint32[] event_ids,
            BusName sender
        ) throws Error;

        public abstract uint32[] insert_events (
            [DBus (signature = "a(asaasay)")] Variant events,
            BusName sender
        ) throws Error;

        public abstract void install_monitor (
            ObjectPath monitor_path,
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant event_templates,
            BusName owner
        ) throws Error;

        public abstract void remove_monitor (
            ObjectPath monitor_path,
            BusName owner
        ) throws Error;

        public abstract void quit () throws Error;

        [DBus (name = "extensions")]
        public abstract string[] extensions { owned get; }

        [DBus (name = "version")]
        public abstract VersionStruct version { owned get; }

    }

    [DBus (name = "org.gnome.zeitgeist.Monitor")]
    public interface RemoteMonitor : Object
    {

        public async abstract void notify_insert (
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant events
        ) throws IOError, EngineError;

        public async abstract void notify_delete (
            [DBus (signature = "(xx)")] Variant time_range,
            uint32[] event_ids
        ) throws IOError;

    }

    /* FIXME: Remove this! Only here because of a bug in Vala (see ext-fts) */
    [DBus (name = "org.gnome.zeitgeist.Index")]
    public interface RemoteSimpleIndexer : Object
    {
        public abstract async void search (
            string query_string,
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant filter_templates,
            uint offset, uint count, uint result_type,
            [DBus (signature = "a(asaasay)")] out Variant events,
            out uint matches) throws Error;
        public abstract async void search_with_relevancies (
            string query_string,
            [DBus (signature = "(xx)")] Variant time_range,
            [DBus (signature = "a(asaasay)")] Variant filter_templates,
            uint storage_state, uint offset, uint count, uint result_type,
            [DBus (signature = "a(asaasay)")] out Variant events,
            out double[] relevancies, out uint matches) throws Error;
    }
    
    /* FIXME: Remove this! Only here because of a bug in Vala (see ext-fts) */
    [DBus (name = "org.freedesktop.NetworkManager")]
    public interface NetworkManagerDBus : Object
    {
        [DBus (name = "state")]
        public abstract uint32 state () throws IOError;
        public signal void state_changed (uint32 state);
    }
    
    /* FIXME: Remove this! Only here because of a bug in Vala (see ext-fts) */
    [DBus (name = "net.connman.Manager")]
    public interface ConnmanManagerDBus : Object
    {
        public abstract string get_state () throws IOError;
        public signal void state_changed (string state);
    }

}

// vim:expandtab:ts=4:sw=4
