#include "../../core/renpy.hpp"

namespace transfer {
const GameAdapter& khemia() {
    static const RenpyAdapter game({
        "khemia", "khemiasave", {'B', 'F', 'K', 'H', 'E', 'M', 'I', '1'},
        "Khemia.exe", "Bonfire_khemia",
        {"Khemia", "Khemia-0.4-win"}, {"Khemia.app"}, {}
    }, "Khemia-1733067824", true);
    return game;
}
}
