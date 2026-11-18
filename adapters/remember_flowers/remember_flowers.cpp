#include "../../core/renpy.hpp"

namespace transfer {
const GameAdapter& remember_flowers() {
    static const RenpyAdapter game({
        "remember_flowers", "rtfsave", {'B', 'F', 'R', 'T', 'F', 'P', 'T', '1'},
        "RemembertheFlowers.exe", "Bonfire_remember_flowers",
        {"RemembertheFlowers", "Remember the Flowers - Part I"}, {"RemembertheFlowers.app"}, {}
    }, "RemembertheFlowers-1617808159", true);
    return game;
}
}
