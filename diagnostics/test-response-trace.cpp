#include "motor_response_trace.hpp"
#include <cassert>
#include <vector>

int main() {
    motor_response_trace::Counter counter;
    counter.identify(&counter, 11, 1);
    std::vector<std::thread> workers;
    for (int n = 0; n < 4; ++n) {
        workers.emplace_back([&] { for (int i = 0; i < 1000; ++i) counter++; });
    }
    for (auto& worker : workers) worker.join();
    assert(int(counter) == 4000);
    counter = 0;
    assert(int(counter) == 0);
    auto& trace = motor_response_trace::recorder();
    trace.emit(motor_response_trace::Fault, &counter, 11, 1, 0, 0, 25);
    trace.freeze();
    counter++;
    assert(int(counter) == 1);
}
