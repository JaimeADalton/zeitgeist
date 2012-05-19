void on_events_inserted (Zeitgeist.TimeRange tr, Zeitgeist.ResultSet events)
{
    message ("%u events inserted", events.size ());

    while (events.has_next ())
    {
        Zeitgeist.Event event = events.next ();
        for (int i = 0; i < event.num_subjects (); ++i )
        {
            Zeitgeist.Subject subject = event.subjects[i];
            message (" * %s", subject.uri);
        }
    }
}

int main ()
{
    var loop = new MainLoop();

    var time_range = new Zeitgeist.TimeRange.anytime ();
    var template = new GenericArray<Zeitgeist.Event> ();

    var monitor = new Zeitgeist.Monitor(time_range, template);
    Zeitgeist.Log log = new Zeitgeist.Log ();

    monitor.events_inserted.connect (on_events_inserted);
    //monitor.events_deleted.connect (on_events_deleted);

    log.install_monitor (monitor);

    loop.run ();
    return 0;
}
