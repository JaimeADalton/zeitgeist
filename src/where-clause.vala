/* where-clause.vala
 *
 * Copyright © 2011 Collabora Ltd.
 *             By Siegfried-Angel Gevatter Pujals <siegfried@gevatter.com>
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

namespace Zeitgeist
{

    /**
     * This class provides a convenient representation a SQL `WHERE' clause,
     * composed of a set of conditions joined together.
     *
     * The relation between conditions can be either of type *AND* or *OR*, but
     * not both. To create more complex clauses, use several `WhereClause`
     * instances and joining them together using `extend`.
     *
     * Instances of this class can then be used to obtain a line of SQL code and
     * a list of arguments, for use with SQLite 3.
     */
    public class WhereClause : Object
    {

        public enum Type
        {
            AND,
            OR
        }

        private static string[] RELATION_SIGNS = { " AND ", " OR " };

        private static string[] PREFIX_SEARCH_SUPPORTED = {
            "origin", "subj_uri", "subj_current_uri", "subj_origin",
            "actor", "subj_mimetype" };

        private WhereClause.Type clause_type;
        private bool negated;
        private GenericArray<string> conditions;
        private GenericArray<string> arguments;

        public WhereClause (WhereClause.Type type, bool negate=false)
        {
            clause_type = type;
            negated = negate;
            conditions = new GenericArray<string> ();
            arguments = new GenericArray<string> ();
        }

        public void add (string condition, string? argument=null)
        {
            conditions.add (condition);
            if (argument != null)
                arguments.add (argument);
        }

        public void add_with_array (string condition,
            GenericArray<string> args)
        {
            conditions.add (condition);
            for (int i = 0; i < args.length; ++i)
                arguments.add (args[i]);
        }

        public void add_match_condition (string column, int val,
            bool negation=false)
            throws EngineError.INVALID_ARGUMENT
        {
            string sql = "%s %s= %d".printf (column, (negation) ? "!" : "", val);
            add (sql);
        }

        public void add_text_condition (string column, string val,
            bool negation=false)
            throws EngineError.INVALID_ARGUMENT
        {
            string sql = "%s %s= ?".printf (column, (negation) ? "!" : "");
            add (sql, val);
        }

        public void add_wildcard_condition (string column, string needle,
            bool negation=false)
        {
            string search_column;
			switch (column)
			{
				case "origin":
				case "subj_origin":
				case "subj_uri":
				case "subj_current_uri":
					search_column = "uri";
					break;
				case "subj_mimetype":
					search_column = "mimetype";
					break;
				default:
					assert_not_reached ();
			}

            var values = new GenericArray<string> ();
            values.add(needle);
            string optimized_glob = optimize_glob (
                "id", search_column, ref values);

            string sql;
            if (!negation)
                sql = "%s IN (%s)".printf (column, optimized_glob);
            else
                sql = "%s NOT IN (%s) OR %s is NULL".printf (column,
                    optimized_glob, column);
			add_with_array (sql, values);
        }

        public void extend (WhereClause clause)
        {
            if (clause.is_empty ())
                return;
            string sql = clause.get_sql_conditions ();
            add_with_array (sql, clause.arguments);
            /*if not where.may_have_results():
            if self._relation == self.AND:
                self.clear()
            self.register_no_result()
            */
	    }

        public bool is_empty ()
        {
            return conditions.length == 0;
        }

        public bool may_have_results ()
        {
            return conditions.length > 0; // or not self._no_result_member
        }

        /**
         * This is dangerous. Only use it if you're made full of awesome.
         */
        private T[] generic_array_to_unowned_array<T> (GenericArray<T> gptrarr)
        {
            long[] pointers = new long[gptrarr.length + 1];
            Memory.copy(pointers, ((PtrArray *) gptrarr)->pdata,
                (gptrarr.length) * sizeof (void *));
            return (T[]) pointers;
        }

        public string get_sql_conditions ()
        {
            assert (conditions.length > 0);
            string negation_sign = (negated) ? "NOT " : "";
            string relation_sign = RELATION_SIGNS[clause_type];

            if (conditions.length == 1)
                return "%s%s".printf (negation_sign, conditions[0]);
            string conditions_string = string.joinv (relation_sign,
                generic_array_to_unowned_array<string> (conditions));
            return "%s(%s)".printf (negation_sign, conditions_string);
		}

        public unowned GenericArray<string> get_bind_arguments ()
        {
            return arguments;
        }

        /**
         * Return an optimized version of the GLOB statement as described in
         * http://www.sqlite.org/optoverview.html "4.0 The LIKE optimization".
         */
        private static string optimize_glob (string column, string table,
            ref GenericArray<string> args)
            requires (args.length == 1)
        {
            string sql;
            string prefix = args[0];
            if (prefix == "") {
                sql = "SELECT %s FROM %s".printf (column, table);
            }
            else if (false) // ...
            {
                // FIXME: check for all(i == unichr(0x10ffff)...)
            }
            else
            {
                sql = "SELECT %s FROM %s WHERE (value >= ? AND value < ?)"
                    .printf (column, table);
                args.add (get_right_boundary (prefix));
            }
            return sql;
        }

        /**
         * Return the smallest string which is greater than the given `text`.
         */
        protected static string get_right_boundary (string text)
        {
            if (text == "")
                return new StringBuilder ().append_unichar(0x10ffff).str;
            int len = text.char_count () - 1;
            unichar charpoint = text.get_char (text.index_of_nth_char (len));
            string head = text.substring (0, text.index_of_nth_char (len - 1));
            if (charpoint == 0x10ffff)
            {
                // If the last char is the biggest possible char we need to
                // look at the second last.
                return get_right_boundary (head);
            }
            return head +
                new StringBuilder ().append_unichar(charpoint + 1).str;
        }

    }

}

// vim:expandtab:ts=4:sw=4
