//
// Copyright (c) 2008-2017 the Urho3D project.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#pragma once

#include "../Graphics/BillboardSet.h"

namespace Urho3D
{

class ParticleEffect;

/// One particle in the particle system.
struct Particle
{
    /// Velocity.
    Vector3 velocity_;
    /// Original billboard size.
    Vector2 size_;
    /// Time elapsed from creation.
    float timer_;
    /// Lifetime.
    float timeToLive_;
    /// Size scaling value.
    float scale_;
    /// Rotation speed.
    float rotationSpeed_;
    /// Current color animation index.
    unsigned colorIndex_;
    /// Current texture animation index.
    unsigned texIndex_;
};

/// %Particle emitter component.
class URHO3D_API ParticleEmitter : public BillboardSet
{
    URHO3D_OBJECT(ParticleEmitter, BillboardSet);

public:
    /// Construct.
    ParticleEmitter(Context* context);
    /// Destruct.
    virtual ~ParticleEmitter();
    /// Register object factory.
    static void RegisterObject(Context* context);

    /// Handle enabled/disabled state change.
    virtual void OnSetEnabled();
    /// Update before octree reinsertion. Is called from a worker thread.
    virtual void Update(const FrameInfo& frame);

    /// Set particle effect.
    void SetEffect(ParticleEffect* effect);
    /// Set maximum number of particles.
    void SetNumParticles(unsigned num);
    /// Set whether should be emitting. If the state was changed, also resets the emission period timer.
    void SetEmitting(bool enable);
    /// Set whether particles should be serialized. Default true, set false to reduce scene file size.
    void SetSerializeParticles(bool enable);
    //// Set to remove either the emitter component or its owner node from the scene automatically on particle effect completion. Disabled by default.
    void SetAutoRemoveMode(AutoRemoveMode mode);
    /// Reset the emission period timer.
    void ResetEmissionTimer();
    /// Remove all current particles.
    void RemoveAllParticles();
    /// Reset the particle emitter completely. Removes current particles, sets emitting state on, and resets the emission timer.
    void Reset();
    /// Apply not continuously updated values such as the material, the number of particles and sorting mode from the particle effect. Call this if you change the effect programmatically.
    void ApplyEffect();
    /// Magic: give the particles a floor, a map of node columns by their
    /// world X and Z (a column is [x - 0.5, x + 0.5)), for a particle that
    /// is not relative. One that falls below its column's floor stops on
    /// it, or with remove goes. Width or depth 0 takes the floor away; each
    /// is at most 256. The map is a ring: column (x, z) is held at
    /// (x mod width, z mod depth), so a moving window sets only the columns
    /// it gains. Every column starts with no floor.
    void SetFloorMap(unsigned width, unsigned depth, bool remove);
    /// Magic: the floor's window, its lowest X and Z; a column outside it
    /// has no floor.
    void SetFloorOrigin(int x, int z);
    /// Magic: the floor of column (x, z), a world Y.
    void SetFloorHeight(int x, int z, float y);

    /// Return particle effect.
    ParticleEffect* GetEffect() const;

    /// Return maximum number of particles.
    unsigned GetNumParticles() const { return particles_.Size(); }

    /// Return whether is currently emitting.
    bool IsEmitting() const { return emitting_; }

    /// Return whether particles are to be serialized.
    bool GetSerializeParticles() const { return serializeParticles_; }

    /// Return automatic removal mode on particle effect completion.
    AutoRemoveMode GetAutoRemoveMode() const { return autoRemove_; }

    /// Set particles effect attribute.
    void SetEffectAttr(const ResourceRef& value);
    /// Set particles effect attribute.
    ResourceRef GetEffectAttr() const;
    /// Set particles attribute.
    void SetParticlesAttr(const VariantVector& value);
    /// Return particles attribute. Returns particle amount only if particles are not to be serialized.
    VariantVector GetParticlesAttr() const;
    /// Return billboards attribute. Returns billboard amount only if particles are not to be serialized.
    VariantVector GetParticleBillboardsAttr() const;

protected:
    /// Handle scene being assigned.
    virtual void OnSceneSet(Scene* scene);

    /// Create a new particle. Return true if there was room.
    bool EmitNewParticle();
    /// Return a free particle index.
    unsigned GetFreeParticle() const;
    /// Return whether has active particles.
    bool CheckActiveParticles() const;

private:
    /// Handle scene post-update event.
    void HandleScenePostUpdate(StringHash eventType, VariantMap& eventData);
    /// Handle live reload of the particle effect.
    void HandleEffectReloadFinished(StringHash eventType, VariantMap& eventData);

    /// Particle effect.
    SharedPtr<ParticleEffect> effect_;
    /// Particles.
    PODVector<Particle> particles_;
    /// Active/inactive period timer.
    float periodTimer_;
    /// New particle emission timer.
    float emissionTimer_;
    /// Last scene timestep.
    float lastTimeStep_;
    /// Rendering framenumber on which was last updated.
    unsigned lastUpdateFrameNumber_;
    /// Currently emitting flag.
    bool emitting_;
    /// Need update flag.
    bool needUpdate_;
    /// Serialize particles flag.
    bool serializeParticles_;
    /// Ready to send effect finish event flag.
    bool sendFinishedEvent_;
    /// Automatic removal mode.
    AutoRemoveMode autoRemove_;
    /// Magic: the floor map; see SetFloorMap().
    PODVector<float> floor_;
    unsigned floorWidth_ = 0;
    unsigned floorDepth_ = 0;
    int floorX_ = 0;
    int floorZ_ = 0;
    bool floorRemove_ = false;
};

}
