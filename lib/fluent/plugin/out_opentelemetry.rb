# frozen_string_literal: true

# Copyright 2025- Shizuo Fujita
# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#
# Fluentd resolves `@type opentelemetry` by requiring this path. The fork's
# implementation registers both `opentelemetry` and `opentelemetry_radiant`.
require "fluent/plugin/out_opentelemetry_radiant"
