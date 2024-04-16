# Record Change Processing
A module for asynchronously noticing changed records and realizing some desired consequence of those records by processing them in the order that they changed.
This is a sound strategy that can be applied to a variety of tasks such as:
- Denormalizing data that is a function of records that are changed in many code paths
- Implementing a queue

## API
This module abstracts this kind of task such that the programmer must implement an interface called a processor that has three methods:
- `fetch(from:, to:, **kwargs)` that fetches an ordered set of records with changed timestamps that lie between `from` and `to`
- `process(records, **kwargs)` that processes the ordered set of records
- `changed_at(record)` that takes a single record and returns the timestamp at which that record changed

There are a couple of additional constant parameters that the processor must define:
- `EXCESSIVE_COUNT` defines a notion of batching or how much work is an excessive amount of work to perform at once. The processor should limit the number of records returned by `fetch` to this constant.
- `STALE_AGE` lets us specify at which point an event should be considered stale, and therefore ignored. For the denormalization use case, a value of infinity might very well make sense. A couple of distinct concepts are probably conflated into this one concept for the time being.

## The Algorithm
### Window
The strategy that this module uses for asynchronously processing events in order hinges singularly on the ability to keep track of a single timestamp for every distinct type of work. This timestamp, which we will refer to as the tracker, represents the point in time up to which we are recent. Every time we'd like to process a new batch of some type of work, we build a time window based on its tracker. One caveat is that the time window must not have a `finish` that is too recent. This is because records have changed timestamps that refer to a moment in time in which the corresponding change is in general not yet visible in the database. To account for this race condition, we require the window's `finish` to lag some duration before the current time. This is defined at the environment level by `RECORD_CHANGE_WINDOW_BUFFER`. A window's `start` and `finish` times are set once upon initialization **(1)** and then its `finish` is possibly adjusted if the processor's `fetch` returns an excessive number of records **(2)**. The calculations for `start` and `finish` at these two moments in time are as follows:
1. `finish` := `RECORD_CHANGE_WINDOW_BUFFER.ago`, `start` := `max(beginning_of_epoch, STALE_AGE.before(now), tracker)`
1. `finish` := `changed_at(fetched.last)`

In the case where we find an excessive number of records, we then eject all records that share the changed timestamp of the last record found because we can't truly know if we're seeing everything for that timestamp. There could be more records with that timestamp that aren't present in the result set due to `fetch` being limited by `EXCESSIVE_COUNT`. If this ejects everything and nothing remains, we've reached an irreconcilable situation that defeats our entire windowing strategy and an exception is raised. At this point a developer could temporarily increase the processor in question's `EXCESSIVE_COUNT` by environment variable to relieve the blockage.

Finally the tracker is set to the window's `finish` so that the next run will build a window that sets that value as its `start`.
