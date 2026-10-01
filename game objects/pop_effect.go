components {
  id: "particles"
  component: "/assets/pop_particles.particlefx"
}
components {
  id: "pop_effect"
  component: "/scripts/pop_effect.script"
}
embedded_components {
  id: "flash"
  type: "sprite"
  data: "default_animation: \"pop_ring\"\n"
  "material: \"/builtins/materials/sprite.material\"\n"
  "textures {\n"
  "  sampler: \"texture_sampler\"\n"
  "  texture: \"/assets/pop_ring.atlas\"\n"
  "}\n"
  ""
}
