#ifndef RUNNER_WINDOWS_LATENCY_WORKER_H_
#define RUNNER_WINDOWS_LATENCY_WORKER_H_

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

// Process creation and termination can block on Windows. Serialize them away
// from the platform thread and deliver channel replies on that thread only.
class WindowsLatencyWorker {
 public:
  explicit WindowsLatencyWorker(std::function<void()> notify)
      : notify_(std::move(notify)), worker_([this] { Run(); }) {}
  ~WindowsLatencyWorker() { Shutdown(); }
  WindowsLatencyWorker(const WindowsLatencyWorker&) = delete;
  WindowsLatencyWorker& operator=(const WindowsLatencyWorker&) = delete;

  void Request(std::function<void()> work, std::function<void()> reply) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return;
      pending_.push_back({std::move(work), std::move(reply)});
    }
    wake_.notify_one();
  }

  void DrainRepliesUI() {
    std::deque<std::function<void()>> replies;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      replies.swap(completed_);
    }
    for (auto& reply : replies) reply();
  }

  void Shutdown() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
      pending_.clear();
    }
    wake_.notify_one();
    if (worker_.joinable()) worker_.join();
    // Destroy retained method results before the Flutter engine goes away.
    completed_.clear();
  }

 private:
  struct Pending {
    std::function<void()> work;
    std::function<void()> reply;
  };
  void Run() {
    for (;;) {
      Pending request;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        wake_.wait(lock, [this] { return stopping_ || !pending_.empty(); });
        if (stopping_) return;
        request = std::move(pending_.front());
        pending_.pop_front();
      }
      request.work();
      {
        std::lock_guard<std::mutex> lock(mutex_);
        completed_.push_back(std::move(request.reply));
        if (stopping_) return;
      }
      notify_();
    }
  }
  std::function<void()> notify_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<Pending> pending_;
  std::deque<std::function<void()>> completed_;
  bool stopping_ = false;
  std::thread worker_;
};

#endif
