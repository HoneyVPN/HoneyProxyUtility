#include "windows_latency_worker.h"

#include <chrono>
#include <future>
#include <iostream>
#include <stdexcept>
#include <vector>

using namespace std::chrono_literals;

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

int main() {
  try {
    const auto ui_thread = std::this_thread::get_id();
    std::promise<void> started;
    std::promise<void> release;
    auto gate = release.get_future().share();
    std::promise<void> notified;
    auto notification = notified.get_future();
    std::vector<int> replies;
    WindowsLatencyWorker worker([&] { notified.set_value(); });
    worker.Request([&] {
      Require(std::this_thread::get_id() != ui_thread, "probe blocked the UI thread");
      started.set_value();
      gate.wait();  // Models a slow CreateProcess/TerminateJobObject operation.
    }, [&] {
      Require(std::this_thread::get_id() == ui_thread, "reply ran outside the UI thread");
      replies.push_back(1);
    });
    Require(started.get_future().wait_for(2s) == std::future_status::ready,
            "probe did not start");
    // The window can drain messages while the OS operation is still blocked.
    worker.DrainRepliesUI();
    Require(replies.empty(), "probe replied before its operation completed");
    release.set_value();
    Require(notification.wait_for(2s) == std::future_status::ready, "missing window notification");
    Require(replies.empty(), "worker called Flutter directly");
    worker.DrainRepliesUI();
    Require(replies == std::vector<int>{1}, "missing or duplicate reply");
    worker.DrainRepliesUI();
    Require(replies.size() == 1, "duplicate reply on a later window message");
    worker.Shutdown();
    worker.Request([] { throw std::runtime_error("request accepted after shutdown"); }, [] {});

    std::promise<void> pending_started;
    std::promise<void> pending_release;
    auto pending_gate = pending_release.get_future().share();
    WindowsLatencyWorker closing([] {});
    closing.Request([&] { pending_started.set_value(); pending_gate.wait(); },
                    [&] { replies.push_back(2); });
    Require(pending_started.get_future().wait_for(2s) == std::future_status::ready,
            "shutdown fixture did not start");
    closing.Request([] {}, [&] { replies.push_back(3); });
    pending_release.set_value();
    closing.Shutdown();
    closing.DrainRepliesUI();
    Require(replies == std::vector<int>{1}, "shutdown delivered a stale Flutter reply");
    std::cout << "PASS latency worker keeps blocking probes off UI and retires replies\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
