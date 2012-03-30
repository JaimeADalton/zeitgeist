/* db-reader.vala
 *
 * Copyright © 2011 Collabora Ltd.
 *             By Siegfried-Angel Gevatter Pujals <siegfried@gevatter.com>
 *             By Seif Lotfy <seif@lotfy.com>
 * Copyright © 2011 Canonical Ltd.
 *             By Michal Hruby <michal.hruby@canonical.com>
 *
 * Based upon a Python implementation (2009-2011) by:
 *  Markus Korn <thekorn@gmx.net>
 *  Mikkel Kamstrup Erlandsen <mikkel.kamstrup@gmail.com>
 *  Seif Lotfy <seif@lotfy.com>
 *  Siegfried-Angel Gevatter Pujals <siegfried@gevatter.com>
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

using Zeitgeist;
using Zeitgeist.SQLite;
using Zeitgeist.Utils;

namespace Zeitgeist
{

public class DbReader : Object
{

    public Zeitgeist.SQLite.Database database { get; construct; }
    protected unowned Sqlite.Database db;

    protected TableLookup interpretations_table;
    protected TableLookup manifestations_table;
    protected TableLookup mimetypes_table;
    protected TableLookup actors_table;

    protected EventCache cache;

    public DbReader () throws EngineError
    {
        Object (database: new Zeitgeist.SQLite.Database.read_only ());
    }

    construct
    {
        database.set_deletion_callback (delete_from_cache);
        db = database.database;

        interpretations_table = new TableLookup (database, "interpretation");
        manifestations_table = new TableLookup (database, "manifestation");
        mimetypes_table = new TableLookup (database, "mimetype");
        actors_table = new TableLookup (database, "actor");

        cache = new EventCache ();
    }

    protected Event get_event_from_row (Sqlite.Statement stmt, uint32 event_id)
    {
        Event event = new Event ();
        event.id = event_id;
        event.timestamp = stmt.column_int64 (EventViewRows.TIMESTAMP);
        event.interpretation = interpretations_table.get_value (
            stmt.column_int (EventViewRows.INTERPRETATION));
        event.manifestation = manifestations_table.get_value (
            stmt.column_int (EventViewRows.MANIFESTATION));
        event.actor = actors_table.get_value (
            stmt.column_int (EventViewRows.ACTOR));
        event.origin = stmt.column_text (
            EventViewRows.EVENT_ORIGIN_URI);

        // Load payload
        unowned uint8[] data = (uint8[]) stmt.column_blob(
            EventViewRows.PAYLOAD);
        data.length = stmt.column_bytes(EventViewRows.PAYLOAD);
        if (data != null)
        {
            event.payload = new ByteArray();
            event.payload.append(data);
        }
        return event;
    }

    protected Subject get_subject_from_row (Sqlite.Statement stmt)
    {
        Subject subject = new Subject ();
        subject.uri = stmt.column_text (EventViewRows.SUBJECT_URI);
        subject.text = stmt.column_text (EventViewRows.SUBJECT_TEXT);
        subject.storage = stmt.column_text (EventViewRows.SUBJECT_STORAGE);
        subject.origin = stmt.column_text (EventViewRows.SUBJECT_ORIGIN_URI);
        subject.current_uri = stmt.column_text (
            EventViewRows.SUBJECT_CURRENT_URI);
        subject.interpretation = interpretations_table.get_value (
            stmt.column_int (EventViewRows.SUBJECT_INTERPRETATION));
        subject.manifestation = manifestations_table.get_value (
            stmt.column_int (EventViewRows.SUBJECT_MANIFESTATION));
        subject.mimetype = mimetypes_table.get_value (
            stmt.column_int (EventViewRows.SUBJECT_MIMETYPE));
        return subject;
    }

    public GenericArray<Event?> get_events(uint32[] event_ids,
            BusName? sender=null) throws EngineError
    {
        // TODO: Consider if we still want the cache. This should be done
        //  once everything is working, since it adds unneeded complexity.
        //  It'd also benchmark it again first, we may have better options
        //  to enhance the performance of SQLite now, and event processing
        //  will be faster now being C.

        var results = new GenericArray<Event?> ();
        results.length = event_ids.length;
        if (event_ids.length == 0)
            return results;

        uint32[] uncached_ids = new uint32[0];
        for (int i = 0; i < event_ids.length; i++)
        {
            Event? e = cache.get_event (event_ids[i]);
            if (e != null) {
                results.set(i, e);
            } else {
                uncached_ids += event_ids[i];
            }
        }

        if (uncached_ids.length == 0)
            return results;

        var sql_event_ids = database.get_sql_string_from_event_ids (uncached_ids);
        string sql = """
            SELECT * FROM event_view
            WHERE id IN (%s)
            """.printf (sql_event_ids);

        Sqlite.Statement stmt;
        int rc = db.prepare_v2 (sql, -1, out stmt);
        database.assert_query_success (rc, "SQL error");

        var events = new HashTable<uint32, Event?> (direct_hash, direct_equal);

        // Create Events and Subjects from rows
        while ((rc = stmt.step ()) == Sqlite.ROW)
        {
            uint32 event_id = (uint32) stmt.column_int64 (EventViewRows.ID);
            Event? event = events.lookup (event_id);
            if (event == null)
            {
                event = get_event_from_row(stmt, event_id);
                events.insert (event_id, event);
            }
            Subject subject = get_subject_from_row(stmt);
            event.add_subject(subject);
        }
        if (rc != Sqlite.DONE)
        {
            throw new EngineError.DATABASE_ERROR ("Error: %d, %s\n",
                rc, db.errmsg ());
        }

        // Sort events according to the sequence of event_ids
        results.length = event_ids.length;
        int i = 0;
        foreach (var id in event_ids)
        {
            Event e = events.lookup (id);
            if (e != null)
                cache.cache_event (e);
            results.set(i++, e);
        }

        return results;
    }

    public uint32[] find_event_ids (TimeRange time_range,
        GenericArray<Event> event_templates,
        uint storage_state, uint max_events, uint result_type,
        BusName? sender=null) throws EngineError
    {

        WhereClause where = new WhereClause (WhereClause.Type.AND);

        /**
         * We are using the unary operator here to tell SQLite to not use
         * the index on the timestamp column at the first place. This is a
         * "fix" for (LP: #672965) based on some benchmarks, which suggest
         * a performance win, but we might not oversee all implications.
         * (See http://www.sqlite.org/optoverview.html, section 6.0).
         *    -- Markus Korn, 29/11/2010
         */
        if (time_range.start != 0)
            where.add (("+timestamp >= %" + int64.FORMAT).printf(
                time_range.start));
        if (time_range.end != 0)
            where.add (("+timestamp <= %" + int64.FORMAT).printf(
                time_range.end));

        if (storage_state == StorageState.AVAILABLE ||
            storage_state == StorageState.NOT_AVAILABLE)
        {
            where.add ("(subj_storage_state=? OR subj_storage_state IS NULL)",
                storage_state.to_string ());
        }
        else if (storage_state != StorageState.ANY)
        {
            throw new EngineError.INVALID_ARGUMENT(
                "Unknown storage state '%u'".printf(storage_state));
        }

        WhereClause tpl_conditions = get_where_clause_from_event_templates (
            event_templates);
        where.extend (tpl_conditions);
        //if (!where.may_have_results ())
        //    return new uint32[0];

        string sql = "SELECT id FROM event_view ";
        string where_sql = "";
        if (!where.is_empty ())
        {
            where_sql = "WHERE " + where.get_sql_conditions ();
        }

        switch (result_type)
        {
            case ResultType.MOST_RECENT_EVENTS:
                sql += where_sql + " ORDER BY timestamp DESC";
                break;
            case ResultType.LEAST_RECENT_EVENTS:
                sql += where_sql + " ORDER BY timestamp ASC";
                break;
            case ResultType.MOST_RECENT_EVENT_ORIGIN:
                sql += group_and_sort ("origin", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_EVENT_ORIGIN:
                sql += group_and_sort ("origin", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_EVENT_ORIGIN:
                sql += group_and_sort ("origin", where_sql, false, false);
                break;
            case ResultType.LEAST_POPULAR_EVENT_ORIGIN:
                sql += group_and_sort ("origin", where_sql, true, true);
                break;
            case ResultType.MOST_RECENT_SUBJECTS:
                sql += group_and_sort ("subj_id", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_SUBJECTS:
                sql += group_and_sort ("subj_id", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_SUBJECTS:
                sql += group_and_sort ("subj_id", where_sql, false, false);
                break;
            case ResultType.LEAST_POPULAR_SUBJECTS:
                sql += group_and_sort ("subj_id", where_sql, true, true);
                break;
            case ResultType.MOST_RECENT_CURRENT_URI:
                sql += group_and_sort ("subj_id_current", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_CURRENT_URI:
                sql += group_and_sort ("subj_id_current", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_CURRENT_URI:
                sql += group_and_sort ("subj_id_current", where_sql,
                    false, false);
                break;
            case ResultType.LEAST_POPULAR_CURRENT_URI:
                sql += group_and_sort ("subj_id_current", where_sql,
                    true, true);
                break;
            case ResultType.MOST_RECENT_ACTOR:
                sql += group_and_sort ("actor", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_ACTOR:
                sql += group_and_sort ("actor", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_ACTOR:
                sql += group_and_sort ("actor", where_sql, false, false);
                break;
            case ResultType.LEAST_POPULAR_ACTOR:
                sql += group_and_sort ("actor", where_sql, true, true);
                break;
            case ResultType.OLDEST_ACTOR:
                sql += group_and_sort ("actor", where_sql, true, null, "min");
                break;
            case ResultType.MOST_RECENT_ORIGIN:
                sql += group_and_sort ("subj_origin", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_ORIGIN:
                sql += group_and_sort ("subj_origin", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_ORIGIN:
                sql += group_and_sort ("subj_origin", where_sql, false, false);
                break;
            case ResultType.LEAST_POPULAR_ORIGIN:
                sql += group_and_sort ("subj_origin", where_sql, true, true);
                break;
            case ResultType.MOST_RECENT_SUBJECT_INTERPRETATION:
                sql += group_and_sort ("subj_interpretation", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_SUBJECT_INTERPRETATION:
                sql += group_and_sort ("subj_interpretation", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_SUBJECT_INTERPRETATION:
                sql += group_and_sort ("subj_interpretation", where_sql,
                    false, false);
                break;
            case ResultType.LEAST_POPULAR_SUBJECT_INTERPRETATION:
                sql += group_and_sort ("subj_interpretation", where_sql,
                    true, true);
                break;
            case ResultType.MOST_RECENT_MIMETYPE:
                sql += group_and_sort ("subj_mimetype", where_sql, false);
                break;
            case ResultType.LEAST_RECENT_MIMETYPE:
                sql += group_and_sort ("subj_mimetype", where_sql, true);
                break;
            case ResultType.MOST_POPULAR_MIMETYPE:
                sql += group_and_sort ("subj_mimetype", where_sql,
                    false, false);
                break;
            case ResultType.LEAST_POPULAR_MIMETYPE:
                sql += group_and_sort ("subj_mimetype", where_sql,
                    true, true);
                break;
            default:
                string error_message = "Invalid ResultType.";
                warning (error_message);
                throw new EngineError.INVALID_ARGUMENT (error_message);
        }

        int rc;
        Sqlite.Statement stmt;

        rc = db.prepare_v2 (sql, -1, out stmt);
        database.assert_query_success(rc, "SQL error");

        var arguments = where.get_bind_arguments ();
        for (int i = 0; i < arguments.length; ++i)
            stmt.bind_text (i + 1, arguments[i]);

#if EXPLAIN_QUERIES
        database.explain_query (stmt);
#endif

        uint32[] event_ids = {};

        while ((rc = stmt.step()) == Sqlite.ROW)
        {
            var event_id = (uint32) uint64.parse(
                stmt.column_text (EventViewRows.ID));
            // Events are supposed to be contiguous in the database
            if (event_ids.length == 0 || event_ids[event_ids.length-1] != event_id) {
                event_ids += event_id;
                if (event_ids.length == max_events) break;
            }
        }
        if (rc != Sqlite.DONE && rc != Sqlite.ROW)
        {
            string error_message = "Error in find_event_ids: %d, %s".printf (
                rc, db.errmsg ());
            warning (error_message);
            throw new EngineError.DATABASE_ERROR (error_message);
        }

        return event_ids;
    }

    public GenericArray<Event?> find_events (TimeRange time_range,
        GenericArray<Event> event_templates,
        uint storage_state, uint max_events, uint result_type,
        BusName? sender=null) throws EngineError
    {
        return get_events (find_event_ids (time_range, event_templates,
            storage_state, max_events, result_type));
    }

    private struct RelatedUri {
        public uint32 id;
        public int64 timestamp;
        public string uri;
        public int32 counter;
    }

    public string[] find_related_uris (TimeRange time_range,
        GenericArray<Event> event_templates,
        GenericArray<Event> result_event_templates,
        uint storage_state, uint max_results, uint result_type,
        BusName? sender=null) throws EngineError
    {
        /**
        * Return a list of subject URIs commonly used together with events
        * matching the given template, considering data from within the
        * indicated timerange.
        * Only URIs for subjects matching the indicated `result_event_templates`
        * and `result_storage_state` are returned.
        */
        if (result_type == ResultType.MOST_RECENT_EVENTS ||
            result_type == ResultType.LEAST_RECENT_EVENTS)
        {

            // We pick out the ids for relational event so we can set them as
            // roots the ids are taken from the events that match the
            // events_templates
            uint32[] ids = find_event_ids (time_range, event_templates,
                storage_state, 0, ResultType.LEAST_RECENT_EVENTS);

            if (event_templates.length > 0 && ids.length == 0)
            {
                throw new EngineError.INVALID_ARGUMENT (
                    "No results found for the event_templates");
            }

            // Pick out the result_ids for the filtered results we would like to
            // take into account the ids are taken from the events that match
            // the result_event_templates if no result_event_templates are set we
            // consider all results as allowed
            uint32[] result_ids;
            result_ids = find_event_ids (time_range, result_event_templates,
                storage_state, 0, ResultType.LEAST_RECENT_EVENTS);

            // From here we create several graphs with the maximum depth of 2
            // and push all the nodes and vertices (events) in one pot together

            uint32[] pot = new uint32[ids.length + result_ids.length];

            for (uint32 i=0; i < ids.length; i++)
                pot[i] = ids[i];
            for (uint32 i=0; i < result_ids.length; i++)
                pot[ids.length + i] = result_ids[ids.length + i];

            Sqlite.Statement stmt;

            var sql_event_ids = database.get_sql_string_from_event_ids (pot);
            string sql = """
               SELECT id, timestamp, subj_uri FROM event_view 
               WHERE id IN (%s) ORDER BY timestamp ASC
               """.printf (sql_event_ids);

            int rc = db.prepare_v2 (sql, -1, out stmt);

            database.assert_query_success(rc, "SQL error");

            // FIXME: fix this ugly code
            var temp_related_uris = new GenericArray<RelatedUri?>();

            while ((rc = stmt.step()) == Sqlite.ROW)
            {
                RelatedUri ruri = RelatedUri(){
                    id = (uint32) uint64.parse(stmt.column_text (0)),
                    timestamp = stmt.column_int64 (1),
                    uri = stmt.column_text (2),
                    counter = 0
                };
                temp_related_uris.add (ruri);
            }

            // RelatedUri[] related_uris = new RelatedUri[temp_related_uris.length];
            // for (int i=0; i<related_uris.length; i++)
            //    related_uris[i] = temp_related_uris[i];

            if (rc != Sqlite.DONE)
            {
                string error_message =
                    "Error in find_related_uris: %d, %s".printf (
                    rc, db.errmsg ());
                warning (error_message);
                throw new EngineError.DATABASE_ERROR (error_message);
            }

            var uri_counter = new HashTable<string, RelatedUri?>(
                str_hash, str_equal);

            for (int i = 0; i < temp_related_uris.length; i++)
            {
                var window = new GenericArray<unowned RelatedUri?>();

                bool count_in_window = false;
                for (int j = int.max (0, i - 5);
                    j < int.min (i, temp_related_uris.length);
                    j++)
                {
                    window.add(temp_related_uris[j]);
                    if (temp_related_uris[j].id in ids)
                        count_in_window = true;
                }

                if (count_in_window)
                {
                    for (int j = 0; j < window.length; j++)
                    {
                        if (uri_counter.lookup (window[j].uri) == null)
                        {
                            RelatedUri ruri = RelatedUri ()
                            {
                                id = window[j].id,
                                timestamp = window[j].timestamp,
                                uri = window[j].uri,
                                counter = 0
                            };
                            uri_counter.insert (window[j].uri, ruri);
                        }
                        uri_counter.lookup (window[j].uri).counter++;
                        if (uri_counter.lookup (window[j].uri).timestamp
                                < window[j].timestamp)
                        {
                            uri_counter.lookup (window[j].uri).timestamp =
                                window[j].timestamp;
                        }
                    }
                }
            }


            // We have the big hashtable with the structs, now we sort them by
            // most used and limit the result then sort again
            List<RelatedUri?> temp_ruris = new  List<RelatedUri?>();
            List<RelatedUri?> values = new List<RelatedUri?>();

            foreach (var uri in uri_counter.get_values())
                values.append(uri);

            values.sort ((a, b) => a.counter - b.counter);
            values.sort ((a, b) => {
                    int64 delta = a.timestamp - b.timestamp;
                    if (delta < 0) return 1;
                    else if (delta > 0) return -1;
                    else return 0;
                });

            foreach (RelatedUri ruri in values)
            {
                if (temp_ruris.length() < max_results)
                    temp_ruris.append(ruri);
                else
                    break;
            }

            // Sort by recency
            if (result_type == 1)
                temp_ruris.sort ((a, b) => {
                    int64 delta = a.timestamp - b.timestamp;
                    if (delta < 0) return 1;
                    else if (delta > 0) return -1;
                    else return 0;});

            string[] results = new string[temp_ruris.length()];

            int i = 0;
            foreach (var uri in temp_ruris)
            {
                results[i] = uri.uri;
                stdout.printf("%i %lld %s\n", uri.counter,
                    uri.timestamp,
                    uri.uri);
                i++;
            }

            return results;
        }
        else
        {
            throw new EngineError.DATABASE_ERROR ("Unsupported ResultType.");
        }
    }

    /**
     * Clear all resources Engine is using (close database connection, etc.).
     *
     * After executing this method on an instance, no other function
     * may be called.
     */
    public virtual void close ()
    {
        database.close ();
    }

    // Used by find_event_ids
    private string group_and_sort (string field, string where_sql,
        bool time_asc=false, bool? count_asc=null,
        string aggregation_type="max")
    {
        string time_sorting = (time_asc) ? "ASC" : "DESC";
        string aggregation_sql = "";
        string order_sql = "";

        if (count_asc != null)
        {
            aggregation_sql = ", COUNT(%s) AS num_events".printf (field);
            order_sql = "num_events %s,".printf ((count_asc) ? "ASC" : "DESC");
        }

        return """
            NATURAL JOIN (
                SELECT %s,
                %s(timestamp) AS timestamp
                %s
                FROM event_view %s
                GROUP BY %s)
            GROUP BY %s
            ORDER BY %s timestamp %s
            """.printf (
                field,
                aggregation_type,
                aggregation_sql,
                where_sql,
                field,
                field,
                order_sql, time_sorting);
    }

    // Used by find_event_ids
    protected WhereClause get_where_clause_from_event_templates (
        GenericArray<Event> templates) throws EngineError
    {
        WhereClause where = new WhereClause (WhereClause.Type.OR);
        for (int i = 0; i < templates.length; ++i)
        {
            Event event_template = templates[i];
            where.extend (
                get_where_clause_from_event_template (event_template));
        }
        return where;
    }

    // Used by get_where_clause_from_event_templates
    private WhereClause get_where_clause_from_event_template (Event template)
        throws EngineError
    {
            WhereClause where = new WhereClause (WhereClause.Type.AND);

            // Event ID
            if (template.id != 0)
                where.add ("id=?", template.id.to_string());

            // Interpretation
            if (!is_empty_string (template.interpretation))
            {
                assert_no_wildcard ("interpretation", template.interpretation);
                WhereClause subwhere = get_where_clause_for_symbol (
                    "interpretation", template.interpretation,
                    interpretations_table);
                if (!subwhere.is_empty ())
                    where.extend (subwhere);
            }

            // Manifestation
            if (!is_empty_string (template.manifestation))
            {
                assert_no_wildcard ("manifestation", template.interpretation);
                WhereClause subwhere = get_where_clause_for_symbol (
                    "manifestation", template.manifestation,
                    manifestations_table);
                if (!subwhere.is_empty ())
                   where.extend (subwhere);
            }

            // Actor
            if (!is_empty_string (template.actor))
            {
                string val = template.actor;
                bool like = parse_wildcard (ref val);
                bool negated = parse_negation (ref val);

                if (like)
                    where.add_wildcard_condition ("actor", val, negated);
                else
                    where.add_match_condition ("actor",
                        actors_table.get_id (val), negated);
            }

            // Origin
            if (!is_empty_string (template.origin))
            {
                string val = template.origin;
                bool like = parse_wildcard (ref val);
                bool negated = parse_negation (ref val);
                assert_no_noexpand (val, "origin");

                if (like)
                    where.add_wildcard_condition ("origin", val, negated);
                else
                    where.add_text_condition_subquery ("origin", val, negated);
            }

            // Subject templates within the same event template are AND'd
            // See LP bug #592599.
            for (int i = 0; i < template.num_subjects(); ++i)
            {
                Subject subject_template = template.subjects[i];

                // Subject interpretation
                if (!is_empty_string (subject_template.interpretation))
                {
                    assert_no_wildcard ("subject interpretation",
                        template.interpretation);
                    WhereClause subwhere = get_where_clause_for_symbol (
                        "subj_interpretation", subject_template.interpretation,
                        interpretations_table);
                    if (!subwhere.is_empty ())
                        where.extend (subwhere);
                }

                // Subject manifestation
                if (!is_empty_string (subject_template.manifestation))
                {
                    assert_no_wildcard ("subject manifestation",
                        subject_template.manifestation);
                    WhereClause subwhere = get_where_clause_for_symbol (
                        "subj_manifestation", subject_template.manifestation,
                        manifestations_table);
                    if (!subwhere.is_empty ())
                        where.extend (subwhere);
                }

                // Mime-Type
                if (!is_empty_string (subject_template.mimetype))
                {
                    string val = subject_template.mimetype;
                    bool like = parse_wildcard (ref val);
                    bool negated = parse_negation (ref val);
                    assert_no_noexpand (val, "mime-type");

                    if (like)
                        where.add_wildcard_condition (
                            "subj_mimetype", val, negated);
                    else
                        where.add_match_condition ("subj_mimetype",
                            mimetypes_table.get_id (val), negated);
                }

                // URI
                if (!is_empty_string (subject_template.uri))
                {
                    string val = subject_template.uri;
                    bool like = parse_wildcard (ref val);
                    bool negated = parse_negation (ref val);
                    assert_no_noexpand (val, "uri");

                    if (like)
                        where.add_wildcard_condition ("subj_id", val, negated);
                    else
                        where.add_text_condition_subquery ("subj_id", val, negated);
                }

                // Origin
                if (!is_empty_string (subject_template.origin))
                {
                    string val = subject_template.origin;
                    bool like = parse_wildcard (ref val);
                    bool negated = parse_negation (ref val);
                    assert_no_noexpand (val, "subject origin");

                    if (like)
                        where.add_wildcard_condition (
                            "subj_origin", val, negated);
                    else
                        where.add_text_condition_subquery (
                            "subj_origin", val, negated);
                }

                // Text
                if (!is_empty_string (subject_template.text))
                {
                    // Negation, noexpand and prefix search aren't supported
                    // for subject texts, but "!", "+" and "*" are valid as
                    // plain text characters.
                    where.add_text_condition_subquery ("subj_text_id",
                        subject_template.text, false);
                }

                // Current URI
                if (!is_empty_string (subject_template.current_uri))
                {
                    string val = subject_template.current_uri;
                    bool like = parse_wildcard (ref val);
                    bool negated = parse_negation (ref val);
                    assert_no_noexpand (val, "current_uri");

                    if (like)
                        where.add_wildcard_condition (
                            "subj_id_current", val, negated);
                    else
                        where.add_text_condition_subquery (
                            "subj_id_current", val, negated);
                }

                // Subject storage
                if (!is_empty_string (subject_template.storage))
                {
                    string val = subject_template.storage;
                    assert_no_negation ("subject storage", val);
                    assert_no_wildcard ("subject storage", val);
                    assert_no_noexpand (val, "subject storage");
                    where.add_text_condition_subquery ("subj_storage_id", val);
                }
            }

            return where;
    }

    // Used by get_where_clause_from_event_templates
    /**
     * If the value starts with the negation operator, throw an
     * error.
     */
    protected void assert_no_negation (string field, string val)
        throws EngineError
    {
        if (!val.has_prefix ("!"))
            return;
        string error_message =
            "Field '%s' doesn't support negation".printf (field);
        warning (error_message);
        throw new EngineError.INVALID_ARGUMENT (error_message);
    }

    // Used by get_where_clause_from_event_templates
    /**
     * If the value starts with the negation operator, throw an
     * error.
     */
    protected void assert_no_noexpand (string field, string val)
        throws EngineError
    {
        if (!val.has_prefix ("+"))
            return;
        string error_message =
            "Field '%s' doesn't support the no-expand operator".printf (field);
        warning (error_message);
        throw new EngineError.INVALID_ARGUMENT (error_message);
    }

    // Used by get_where_clause_from_event_templates
    /**
     * If the value ends with the wildcard character, throw an error.
     */
    protected void assert_no_wildcard (string field, string val)
        throws EngineError
    {
        if (!val.has_suffix ("*"))
            return;
        string error_message =
            "Field '%s' doesn't support prefix search".printf (field);
        warning (error_message);
        throw new EngineError.INVALID_ARGUMENT (error_message);
    }

    protected WhereClause get_where_clause_for_symbol (string table_name,
        string symbol, TableLookup lookup_table) throws EngineError
    {
        string _symbol = symbol;
        bool negated = parse_negation (ref _symbol);
        bool noexpand = parse_noexpand (ref _symbol);
        List<unowned string> symbols;
        if (noexpand)
            symbols = new List<unowned string> ();
        else
            symbols = Symbol.get_all_children (_symbol);
        symbols.prepend (_symbol);

        WhereClause subwhere = new WhereClause(
            WhereClause.Type.OR, negated);

        if (symbols.length () == 1)
        {
            subwhere.add_match_condition (table_name,
                lookup_table.get_id (_symbol));
        }
        else
        {
            var sb = new StringBuilder ();
            foreach (unowned string uri in symbols)
            {
                sb.append_printf ("%d,", lookup_table.get_id (uri));
            }
            sb.truncate (sb.len - 1);

            string sql = "%s IN (%s)".printf(table_name, sb.str);
            subwhere.add(sql);
        }

        return subwhere;
    }

    private void delete_from_cache (string table, int64 rowid)
    {
        TableLookup table_lookup;

        if (table == "interpretation")
            table_lookup = interpretations_table;
        else if (table == "manifestation")
            table_lookup = manifestations_table;
        else if (table == "mimetype")
            table_lookup = mimetypes_table;
        else if (table == "actor")
            table_lookup = actors_table;
        else
            return;

        table_lookup.remove((int) rowid);
    }

}

}

// vim:expandtab:ts=4:sw=4
