# Cria o target PapagaioTests (unit test bundle, host = app) e liga no scheme.
# Uso: ruby Scripts/adiciona-target-de-testes.rb
require "xcodeproj"

# Funciona também quando chamado fora da raiz do checkout.
Dir.chdir(File.expand_path("..", __dir__))

PROJ = "Loro.xcodeproj"
proj = Xcodeproj::Project.open(PROJ)

app = proj.targets.find { |t| t.name == "Loro" } || abort("target Loro não encontrado")

# O bundle de testes resolve os símbolos do módulo Papagaio dentro do
# hospedeiro em runtime; sem export_dynamic o link do bundle falha com
# "Undefined symbols Papagaio.…".
app.build_configurations.each do |cfg|
  flags = Array(cfg.build_settings["OTHER_LDFLAGS"])
  flags += ["-Wl,-export_dynamic"] unless flags.include?("-Wl,-export_dynamic")
  cfg.build_settings["OTHER_LDFLAGS"] = flags
end

# O app compila como módulo "Papagaio" para os testes usarem
# `@testable import Papagaio` como escrito (o produto é Ōmu.app).
app.build_configurations.each do |cfg|
  cfg.build_settings["PRODUCT_MODULE_NAME"] = "Papagaio"
end

tests = proj.targets.find { |t| t.name == "PapagaioTests" }
target_novo = tests.nil?
if target_novo
  tests = proj.new_target(
    :unit_test_bundle,
    "PapagaioTests",
    :osx,
    "26.0",
    nil,
    :swift
  )
  tests.add_dependency(app)
end

# O produto é dinâmico: app e bundle de testes carregam a mesma imagem em vez
# de cada um incorporar uma cópia estática das classes do PapagaioCore.
core = app.package_product_dependencies.find { |d| d.product_name == "PapagaioCore" }
if core && !tests.package_product_dependencies.include?(core)
  tests.package_product_dependencies << core
end

# Grupo espelhando a pasta no disco. Todos os testes Swift entram no target;
# manter uma lista manual foi o que deixou suítes novas órfãs no passado.
grupo = proj.main_group["PapagaioTests"] ||
        proj.main_group.new_group("PapagaioTests", "PapagaioTests")
Dir.children("PapagaioTests").grep(/\.swift\z/).sort.each do |nome|
  ref = grupo.files.find { |arquivo| arquivo.path == nome } || grupo.new_reference(nome)
  unless tests.source_build_phase.files_references.include?(ref)
    tests.source_build_phase.add_file_reference(ref)
  end
end

# Frameworks do app precisam estar visíveis ao bundle de testes.
tests.build_configurations.each do |cfg|
  s = cfg.build_settings
  app_cfg = app.build_configurations.find { |candidata| candidata.name == cfg.name }
  s["PRODUCT_BUNDLE_IDENTIFIER"] = "com.papagaio.tests"
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["GENERATE_INFOPLIST_FILE"] = "YES"
  # O nome visível do bundle pode diferir do executável (Ōmu.app / Omu).
  # Leia ambos do host para o script não restaurar um caminho inválido.
  abort("configuração #{cfg.name} ausente no host Loro") unless app_cfg
  host_settings = app_cfg.build_settings
  produto = host_settings.fetch("PRODUCT_NAME", app.name)
  executavel = host_settings.fetch("EXECUTABLE_NAME", produto)
  s["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/#{produto}.app/Contents/MacOS/#{executavel}"
  s["SWIFT_VERSION"] = "6.0"
  s["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
  s["CODE_SIGN_STYLE"] = "Automatic"
  # Em macOS 27, um bundle ad hoc não pode ser injetado num host assinado por
  # um time. Herdar o time do app mantém ambos com o mesmo TeamIdentifier.
  s["DEVELOPMENT_TEAM"] = app_cfg.build_settings["DEVELOPMENT_TEAM"] if app_cfg
  # O bundle compila contra os módulos do host sem relinkar PapagaioCore.
  # Esta busca mantém visíveis os módulos C transitivos do FluidAudio.
  s["FRAMEWORK_SEARCH_PATHS"] = ["$(inherited)", "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"]
  s.delete("INFOPLIST_FILE")
end

# Os símbolos do módulo Papagaio vivem no hospedeiro: o bundle os resolve
# em runtime, então o link não pode exigir resolução imediata.
tests.build_configurations.each do |cfg|
  flags = Array(cfg.build_settings["OTHER_LDFLAGS"])
  flags += ["-undefined", "dynamic_lookup"] unless flags.include?("dynamic_lookup")
  cfg.build_settings["OTHER_LDFLAGS"] = flags
end

# Liga no Test action do scheme Loro.
scheme_path = File.join(PROJ, "xcshareddata/xcschemes/Loro.xcscheme")
scheme = Xcodeproj::XCScheme.new(scheme_path)
incluido = scheme.test_action.testables.any? do |testable|
  testable.buildable_references.any? { |ref| ref.target_uuid == tests.uuid }
end
unless incluido
  scheme.add_test_target(tests)
  scheme.save!
end

proj.save
puts "ok: target PapagaioTests sincronizado e ligado no scheme"
