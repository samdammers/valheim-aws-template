locals {
  region = var.aws_region

  server_fqdn = "valheim.${var.domain}"
  api_fqdn    = "api.valheim.${var.domain}"

  tags = {
    Service = "valheim"
  }

  world_presets   = yamldecode(file("${path.module}/world-presets.yaml"))
  selected_preset = var.world_preset != "" ? local.world_presets[var.world_preset] : {}

  # Explicit override wins; otherwise fall back to the preset's value for that
  # dial (or null - vanilla - if there's no preset, or the preset doesn't set
  # it either). Deliberately not coalesce(): that errors if every argument is
  # null, which is exactly the common "no preset, no override" case.
  resolved_modifiers = {
    combat       = var.world_modifiers.combat != null ? var.world_modifiers.combat : try(local.selected_preset.combat, null)
    deathpenalty = var.world_modifiers.deathpenalty != null ? var.world_modifiers.deathpenalty : try(local.selected_preset.deathpenalty, null)
    resources    = var.world_modifiers.resources != null ? var.world_modifiers.resources : try(local.selected_preset.resources, null)
    raids        = var.world_modifiers.raids != null ? var.world_modifiers.raids : try(local.selected_preset.raids, null)
    portals      = var.world_modifiers.portals != null ? var.world_modifiers.portals : try(local.selected_preset.portals, null)
  }

  modifier_flags = join(" ", [for k, v in local.resolved_modifiers : "-modifier ${k} ${v}" if v != null])
  setkey_flags   = join(" ", [for k in var.world_setkeys : "-setkey ${k}"])

  # server_args is a raw escape hatch, appended last, for anything the
  # structured variables above don't cover.
  generated_server_args = trimspace(join(" ", compact([local.modifier_flags, local.setkey_flags, var.server_args])))
}
