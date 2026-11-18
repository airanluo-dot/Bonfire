#include "../../core/renpy.hpp"

namespace transfer {
const GameAdapter& adastra() {
    static const RenpyAdapter game({
        "adastra", "adastrasave", {'B', 'F', 'A', 'D', 'S', 'T', 'R', '1'},
        "Adastra.exe", "Bonfire_adastra",
        {"Adastra", "Adastra-17-win"}, {"Adastra.app"}, {}
    }, "Adastra-1513063297");
    return game;
}
}
