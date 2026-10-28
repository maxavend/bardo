namespace Bardo.Models;

/// <summary>
/// Fans one operation's progress out to every caller waiting on it. Callers can join
/// while the operation runs; progress callbacks arrive on arbitrary threads.
/// </summary>
public sealed class ProgressFanOut<T>
{
    private readonly Lock _gate = new();
    private readonly Dictionary<Guid, Action<T>> _observers = [];
    private T? _latest;
    private bool _hasLatest;

    /// <summary>Adds an observer, which first hears the latest value if there is one.</summary>
    public Guid Add(Action<T> observer)
    {
        var id = Guid.NewGuid();
        bool hasCurrent;
        T? current;
        lock (_gate)
        {
            _observers[id] = observer;
            hasCurrent = _hasLatest;
            current = _latest;
        }
        if (hasCurrent) observer(current!);
        return id;
    }

    public void Remove(Guid id)
    {
        lock (_gate)
        {
            _observers.Remove(id);
        }
    }

    /// <summary>Forgets the last value so a new operation does not start from the previous one's.</summary>
    public void Reset()
    {
        lock (_gate)
        {
            _latest = default;
            _hasLatest = false;
        }
    }

    public void Send(T value)
    {
        Action<T>[] snapshot;
        lock (_gate)
        {
            _latest = value;
            _hasLatest = true;
            snapshot = [.. _observers.Values];
        }
        foreach (var observer in snapshot) observer(value);
    }
}

/// <summary>
/// One download or load at a time, shared by every caller that needs it: setup, Settings,
/// a warm-up and a transcription asking together start it once and all wait on it.
/// </summary>
/// <remarks>
/// A caller that cancels stops waiting at once, but the shared work stops only when the
/// last caller gave up. Work that was stopped may still be unwinding; the next caller
/// waits for it to finish before starting again, so two never write into the same folder.
/// </remarks>
public sealed class SingleFlightOperation<TResult, TProgress>
{
    private sealed class Flight
    {
        public Flight(Func<Flight, Task<TResult>> start)
        {
            Task = start(this);
            Ended = Task.ContinueWith(static _ => { }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }

        /// <summary>Never disposed: an engine may still be running its callbacks when the work ends.</summary>
        public CancellationTokenSource Cancellation { get; } = new();

        public Task<TResult> Task { get; }

        /// <summary>Completes when the work ends, however it ends.</summary>
        public Task Ended { get; }

        public int Waiters { get; set; }
        public bool IsCancelled => Cancellation.IsCancellationRequested;
    }

    private readonly Func<Action<TProgress>, CancellationToken, Task<TResult>> _operation;
    private readonly ProgressFanOut<TProgress> _progress = new();
    private readonly Lock _gate = new();
    private Flight? _current;

    /// <param name="operation">
    /// The shared work. It reports progress through its first argument and stops when its
    /// token is cancelled, which happens only once every caller has cancelled.
    /// </param>
    public SingleFlightOperation(Func<Action<TProgress>, CancellationToken, Task<TResult>> operation)
    {
        _operation = operation;
    }

    /// <summary>Whether the work is running, or still unwinding after it was stopped.</summary>
    public bool IsRunning
    {
        get
        {
            lock (_gate)
            {
                return _current is not null;
            }
        }
    }

    /// <summary>
    /// Joins the running work, or starts it, and waits for its result. Cancelling
    /// <paramref name="cancellationToken"/> returns at once with an
    /// <see cref="OperationCanceledException"/>.
    /// </summary>
    public async Task<TResult> RunAsync(Action<TProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        Flight flight;
        Guid? observer;
        while (true)
        {
            Flight stopping;
            lock (_gate)
            {
                if (_current is not { IsCancelled: true } cancelled)
                {
                    flight = _current ??= Start();
                    flight.Waiters++;
                    observer = progress is null ? null : _progress.Add(progress);
                    break;
                }
                stopping = cancelled;
            }
            // A cancelled operation may still be unwinding; never start a second one until
            // it has stopped. Waiting honours this caller's own cancellation.
            await stopping.Ended.WaitAsync(cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                if (_current == stopping) _current = null;
            }
        }

        try
        {
            return await flight.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                if (observer is { } id) _progress.Remove(id);
                flight.Waiters--;
                // Stop the shared work only when the last caller gave up.
                if (cancellationToken.IsCancellationRequested && flight.Waiters == 0 && _current == flight)
                {
                    flight.Cancellation.Cancel();
                }
            }
        }
    }

    private Flight Start()
    {
        _progress.Reset();
        return new Flight(flight => Task.Run(() => PerformAsync(flight), CancellationToken.None));
    }

    private async Task<TResult> PerformAsync(Flight flight)
    {
        try
        {
            return await _operation(_progress.Send, flight.Cancellation.Token).ConfigureAwait(false);
        }
        finally
        {
            // Cleared before any caller sees the result, so a finished operation never
            // keeps the model marked in use.
            lock (_gate)
            {
                if (_current == flight) _current = null;
            }
        }
    }
}
