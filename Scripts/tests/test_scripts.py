"""Regressões offline dos scripts de validação e configuração do projeto."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="papagaio scripts ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Scripts").mkdir()
        (self.root / "PapagaioCore/.build/out/Products/Debug").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_CALLS=str(self.log), TEST_STATE=str(self.root / "state"))

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_core(self, first="success", second="success", args=(), codesign="success"):
        script = self.root / "Scripts/testa-papagaio-core.sh"
        shutil.copy2(ROOT / "Scripts/testa-papagaio-core.sh", script)
        self.executable("swift", '''
printf 'swift' >> "$TEST_CALLS"
printf ' <%s>' "$@" >> "$TEST_CALLS"
printf '\\n' >> "$TEST_CALLS"
if [[ -e "$TEST_STATE" ]]; then result="$TEST_SECOND"; else
    touch "$TEST_STATE"; result="$TEST_FIRST"
fi
case "$result" in
    success) exit 0 ;;
    attributes) echo 'resource fork, Finder information, or similar detritus not allowed'; exit 1 ;;
    *) echo 'error: compilation failed'; exit 1 ;;
esac
''')
        self.executable("xattr", 'printf "xattr <%s> <%s>\\n" "$1" "$2" >> "$TEST_CALLS"\n')
        self.executable("codesign", '''
printf 'codesign' >> "$TEST_CALLS"
printf ' <%s>' "$@" >> "$TEST_CALLS"
printf '\\n' >> "$TEST_CALLS"
[[ "${TEST_CODESIGN:-success}" == success ]]
''')
        return subprocess.run(["bash", str(script), *args], cwd=self.root,
                              env=dict(self.env, TEST_FIRST=first, TEST_SECOND=second,
                                       TEST_CODESIGN=codesign),
                              capture_output=True, text=True)

    def bundle(self, products=None, config="Debug"):
        """Cria o .xctest de mentira que o build interrompido teria deixado."""
        products = products or self.root / "PapagaioCore/.build/out/Products"
        bundle = products / config / "PapagaioCoreTests.xctest"
        (bundle / "Contents").mkdir(parents=True)
        return bundle

    def calls(self):
        return self.log.read_text().splitlines()

    def test_success_runs_once(self):
        self.assertEqual(self.run_core().returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_compilation_failure_never_runs_stale_tests(self):
        self.assertNotEqual(self.run_core("compile").returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_attribute_recovery_signs_and_reruns(self):
        bundle = self.bundle()
        self.assertEqual(self.run_core("attributes").returncode, 0)
        calls = self.calls()
        swift = [i for i, call in enumerate(calls) if call.startswith("swift <test>")]
        self.assertEqual(len(swift), 2)
        self.assertNotIn("--skip-build", calls[swift[0]])
        self.assertIn("<--skip-build>", calls[swift[1]])
        # Limpa o bundle em profundidade, assina e só então roda sem recompilar.
        limpeza = calls.index(f"xattr <-c> <{bundle}>")
        assinatura = next(i for i, call in enumerate(calls)
                          if call.startswith("codesign") and call.endswith(f"<{bundle}>"))
        self.assertIn(f"xattr <-c> <{bundle}/Contents>", calls)
        self.assertLess(limpeza, assinatura)
        self.assertLess(assinatura, swift[1])

    def test_retry_failure_is_not_success(self):
        self.bundle()
        self.assertNotEqual(self.run_core("attributes", "compile").returncode, 0)
        self.assertEqual(self.log.read_text().count("<--skip-build>"), 1)

    def test_persistent_attributes_give_up(self):
        self.bundle()
        self.assertNotEqual(self.run_core("attributes", "attributes").returncode, 0)
        self.assertEqual(self.log.read_text().count("<--skip-build>"), 5)

    def test_unsigned_bundle_never_runs(self):
        self.bundle()
        self.assertNotEqual(self.run_core("attributes", codesign="failure").returncode, 0)
        self.assertNotIn("--skip-build", self.log.read_text())

    def test_missing_bundle_never_runs_stale_tests(self):
        self.assertNotEqual(self.run_core("attributes").returncode, 0)
        calls = self.log.read_text()
        self.assertNotIn("codesign", calls)
        self.assertNotIn("--skip-build", calls)

    def test_scratch_path_with_spaces(self):
        scratch = self.root / "custom scratch"
        bundle = self.bundle(scratch / "out/Products", "Release")
        result = self.run_core("attributes", args=("--scratch-path", str(scratch), "-c", "release"))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertIn(f"xattr <-c> <{bundle}>", calls)
        self.assertTrue(any(call.startswith("codesign") and call.endswith(f"<{bundle}>") for call in calls))
        self.assertIn(f"swift <test> <--no-parallel> <--skip-build> <--scratch-path> <{scratch}> <-c> <release>", calls)

    def test_scratch_path_equals(self):
        scratch = self.root / "custom scratch"
        bundle = self.bundle(scratch / "out/Products")
        self.assertEqual(self.run_core("attributes", args=(f"--scratch-path={scratch}",)).returncode, 0)
        calls = self.calls()
        self.assertIn(f"xattr <-c> <{bundle}>", calls)
        self.assertTrue(any(call.startswith("codesign") and call.endswith(f"<{bundle}>") for call in calls))
        self.assertIn(f"swift <test> <--no-parallel> <--skip-build> <--scratch-path={scratch}>", calls)

    def test_missing_products_stops_recovery(self):
        shutil.rmtree(self.root / "PapagaioCore/.build")
        self.assertNotEqual(self.run_core("attributes").returncode, 0)
        calls = self.log.read_text()
        self.assertNotIn("xattr", calls)
        self.assertNotIn("codesign", calls)

    def test_target_sync_recovers_scheme_and_keeps_executable(self):
        check = subprocess.run(["ruby", "-rxcodeproj", "-e", ""], capture_output=True)
        if check.returncode:
            self.skipTest("gem xcodeproj ausente")
        shutil.copytree(ROOT / "Loro.xcodeproj", self.root / "Loro.xcodeproj")
        shutil.copytree(ROOT / "PapagaioTests", self.root / "PapagaioTests")
        script = self.root / "Scripts/adiciona-target-de-testes.rb"
        shutil.copy2(ROOT / "Scripts/adiciona-target-de-testes.rb", script)
        scheme = self.root / "Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme"
        tree = ET.parse(scheme)
        tree.getroot().find("TestAction/Testables").clear()
        tree.write(scheme, encoding="utf-8", xml_declaration=True)
        for _ in range(2):
            result = subprocess.run(["ruby", str(script)], cwd=self.bin, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        testables = ET.parse(scheme).getroot().findall("TestAction/Testables/TestableReference")
        self.assertEqual(len(testables), 1)
        project = (self.root / "Loro.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count('TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Ōmu.app/Contents/MacOS/Omu";'), 2)


if __name__ == "__main__":
    unittest.main()
