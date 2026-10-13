#pragma once

// Hand a replacement object from a control thread to the realtime IO thread
// without allocating, blocking, or freeing on the IO thread.
//
// Protocol:
//   control thread: Reap() -> Offer(new)
//   IO thread:      TakePending() -> use -> Retire(old)
//   control thread: Reap() frees the retired object
//
// The IO thread only takes a pending object while the retire slot is free, so
// Retire() after a successful TakePending() always succeeds and the IO thread
// never has to destroy anything. Only the control thread allocates and frees.

#include <atomic>
#include <memory>

namespace soundbridge {

template <typename T> class MappingHandoff {
public:
    MappingHandoff() = default;
    MappingHandoff(const MappingHandoff&) = delete;
    MappingHandoff& operator=(const MappingHandoff&) = delete;
    ~MappingHandoff() { Clear(); }

    /// Control thread: offer a replacement. Returns false when an offer is
    /// still outstanding; the caller then keeps ownership of `next`.
    bool Offer(std::unique_ptr<T>&& next) {
        T* expected = nullptr;
        if (!pending_.compare_exchange_strong(expected, next.get())) {
            return false;
        }
        (void)next.release();
        return true;
    }

    bool HasPending() const { return pending_.load(std::memory_order_acquire) != nullptr; }

    /// IO thread: take the pending object, or null when there is none or the
    /// previous object has not been reaped yet. Caller owns the result.
    T* TakePending() {
        if (pending_.load(std::memory_order_acquire) == nullptr) return nullptr;
        if (retired_.load(std::memory_order_acquire) != nullptr) return nullptr;
        return pending_.exchange(nullptr, std::memory_order_acq_rel);
    }

    /// IO thread: hand the replaced object over for deferred destruction.
    /// Guaranteed to succeed after TakePending() returned non-null.
    bool Retire(T* previous) {
        if (!previous) return true;
        T* expected = nullptr;
        return retired_.compare_exchange_strong(expected, previous);
    }

    /// Control thread: destroy a retired object, if any.
    void Reap() { delete retired_.exchange(nullptr, std::memory_order_acq_rel); }

    /// Control thread, only while the IO side is stopped: drop everything.
    void Clear() {
        delete pending_.exchange(nullptr, std::memory_order_acq_rel);
        delete retired_.exchange(nullptr, std::memory_order_acq_rel);
    }

private:
    std::atomic<T*> pending_{nullptr};
    std::atomic<T*> retired_{nullptr};
};

} // namespace soundbridge
