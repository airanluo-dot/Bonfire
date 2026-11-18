#pragma once
#include "adapter.hpp"

namespace transfer {
class RenpyAdapter : public GameAdapter {
public:
    RenpyAdapter(GameInfo metadata, std::string profile, bool supportsSaveOverride = false);
    bool sharesUserSaves() const override { return true; }
    SaveLimits limits() const override { return {64*1024*1024, 256*1024*1024}; }
    Path identify(const Path& selection) const override;
    Path installation(const Path& root) const override { return root; }
    Path saveDirectory(const Path& root) const override;
    bool acceptsEntry(const std::string& name) const override;
    Progress inventory(const Path& root) const override;
    Progress validate(const Files& files) const override;
    Files capture(const Path& root) const override;
    void install(const Path& root, const Files& files) const override;
protected:
    Path dataRoot(const Path& installation) const;
    virtual Progress summarize(const Files& files) const;
private:
    const std::string profile;
    const bool supportsSaveOverride;
    std::vector<Path> saveDirectories(const Path& installation) const;
};
}
