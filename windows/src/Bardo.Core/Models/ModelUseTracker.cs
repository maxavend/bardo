namespace Bardo.Models;

/// <summary>
/// Counts the operations relying on a loaded model, so it is never unloaded or removed
/// while in use. Once nothing has used it for <c>idleUnloadDelay</c>, it is let go to
/// free its memory.
/// </summary>
public sealed class ModelUseTracker : IDisposable
{
    public static readonly TimeSpan DefaultIdleUnloadDelay = TimeSpan.FromMinutes(30);

    private readonly Lock _gate = new();
    private readonly Action _unload;
    private readonly TimeSpan _idleUnloadDelay;
    private readonly TimeProvider _timeProvider;
    private int _activeOperations;
    private bool _isLoaded;
    private bool _isResetting;
    private ITimer? _idleUnload;
    private long _idleUnloadGeneration;

    /// <param name="unload">Lets go of the loaded model; called only while nothing uses it.</param>
    public ModelUseTracker(Action unload, TimeSpan? idleUnloadDelay = null, TimeProvider? timeProvider = null)
    {
        _unload = unload;
        _idleUnloadDelay = idleUnloadDelay ?? DefaultIdleUnloadDelay;
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public bool IsInUse
    {
        get
        {
            lock (_gate)
            {
                return _activeOperations > 0 || _isResetting;
            }
        }
    }

    /// <summary>
    /// Marks an operation that relies on the model until the returned lease is disposed.
    /// </summary>
    /// <exception cref="ModelInUseException">The model is being removed.</exception>
    public IDisposable Begin()
    {
        lock (_gate)
        {
            if (_isResetting) throw new ModelInUseException();
            _activeOperations++;
            CancelIdleUnload();
        }
        return new Lease(End);
    }

    /// <summary>A model is now loaded; it is let go once it has gone unused long enough.</summary>
    public void MarkLoaded()
    {
        lock (_gate)
        {
            _isLoaded = true;
            if (_activeOperations == 0) ScheduleIdleUnload();
        }
    }

    /// <summary>The model was let go some other way, such as for another model.</summary>
    public void MarkUnloaded()
    {
        lock (_gate)
        {
            _isLoaded = false;
            CancelIdleUnload();
        }
    }

    /// <summary>
    /// Marks the model's removal until the returned lease is disposed; no operation can
    /// begin meanwhile.
    /// </summary>
    /// <exception cref="ModelInUseException">An operation still relies on the model.</exception>
    public IDisposable BeginReset()
    {
        lock (_gate)
        {
            if (_activeOperations > 0 || _isResetting) throw new ModelInUseException();
            _isResetting = true;
            CancelIdleUnload();
        }
        return new Lease(() =>
        {
            lock (_gate)
            {
                _isResetting = false;
            }
        });
    }

    public void Dispose()
    {
        lock (_gate)
        {
            CancelIdleUnload();
        }
    }

    private void End()
    {
        lock (_gate)
        {
            _activeOperations = Math.Max(0, _activeOperations - 1);
            if (_activeOperations == 0 && _isLoaded) ScheduleIdleUnload();
        }
    }

    private void ScheduleIdleUnload()
    {
        CancelIdleUnload();
        var generation = _idleUnloadGeneration;
        _idleUnload = _timeProvider.CreateTimer(_ => UnloadAfterIdleTimeout(generation), null, _idleUnloadDelay, Timeout.InfiniteTimeSpan);
    }

    private void CancelIdleUnload()
    {
        // A timer that already fired may still be waiting for the lock; it must not act.
        _idleUnloadGeneration++;
        _idleUnload?.Dispose();
        _idleUnload = null;
    }

    private void UnloadAfterIdleTimeout(long generation)
    {
        lock (_gate)
        {
            if (generation != _idleUnloadGeneration || _activeOperations > 0 || _isResetting || !_isLoaded) return;
            _isLoaded = false;
            CancelIdleUnload();
            _unload();
        }
    }

    private sealed class Lease(Action end) : IDisposable
    {
        private Action? _end = end;

        public void Dispose() => Interlocked.Exchange(ref _end, null)?.Invoke();
    }
}
