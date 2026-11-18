#include "../../core/renpy.hpp"

namespace transfer {
const GameAdapter& interea() {
    static const RenpyAdapter game({
        "interea", "intereasave", {'B', 'F', 'I', 'N', 'T', 'R', 'E', '1'},
        "Interea.exe", "Bonfire_interea",
        {"Interea", "Interea-0.4-win"}, {"Interea.app"}, {}
    }, "AdastraInterea-1614811255");
    return game;
}
}
