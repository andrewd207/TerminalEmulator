# Top-level build for the TerminalEmulator aggregator.
# Runs every module through pasbuild plus the lazbuild path for the LCL example.
# Each step is attempted independently; the final summary lists any failures.
#
#   make            — build everything (continue on failure, summary at end)
#   make clean      — wipe target/ directories
#   make <module>   — build a single module (TerminalFramework, ViewfpGUI,
#                     ViewLCL, ExampleTerminal, ExampleTerminalLCL, replay)
#   make lcl-lazbuild — build ExampleTerminalLCL via lazbuild

PROFILE ?= debug
PASBUILD ?= pasbuild
LAZBUILD ?= lazbuild
PROJECT_XML := project.xml

PASBUILD_MODULES := \
	TerminalFramework \
	ViewfpGUI \
	ViewLCL \
	ExampleTerminal \
	ExampleTerminalLCL \
	tools/replay

STATUS_DIR := target/build-status
LOG_DIR := $(STATUS_DIR)/logs

.PHONY: all clean help \
	TerminalFramework ViewfpGUI ViewLCL \
	ExampleTerminal ExampleTerminalLCL replay \
	lcl-lazbuild summary

all:
	@rm -rf $(STATUS_DIR)
	@mkdir -p $(LOG_DIR)
	@touch $(STATUS_DIR)/passed $(STATUS_DIR)/failed
	@$(MAKE) --no-print-directory _run STEP=TerminalFramework      CMD='$(PASBUILD) compile -f $(PROJECT_XML) -m TerminalFramework -p $(PROFILE)'
	@$(MAKE) --no-print-directory _run STEP=ViewfpGUI              CMD='$(PASBUILD) compile -f $(PROJECT_XML) -m ViewfpGUI -p $(PROFILE)'
	@$(MAKE) --no-print-directory _run STEP=ViewLCL                CMD='$(PASBUILD) compile -f $(PROJECT_XML) -m ViewLCL -p $(PROFILE)'
	@$(MAKE) --no-print-directory _run STEP=ExampleTerminal        CMD='$(PASBUILD) compile -f $(PROJECT_XML) -m ExampleTerminal -p $(PROFILE)'
	@$(MAKE) --no-print-directory _run STEP=ExampleTerminalLCL     CMD='$(PASBUILD) compile -f $(PROJECT_XML) -m ExampleTerminalLCL -p $(PROFILE)'
	@$(MAKE) --no-print-directory _run STEP=Replay                 CMD='$(PASBUILD) compile -f $(PROJECT_XML) -m Replay -p $(PROFILE)'
	@$(MAKE) --no-print-directory _run STEP=ExampleTerminalLCL-lazbuild CMD='./ExampleTerminalLCL/build.sh'
	@$(MAKE) --no-print-directory _run STEP=LibTermView                CMD='./LibTermView/build.sh'
	@$(MAKE) --no-print-directory _run STEP=ViewGtk4                   CMD='./ViewGtk4/build.sh'
	@$(MAKE) --no-print-directory _run STEP=ExampleTerminalGtk4        CMD='./ExampleTerminalGtk4/build.sh'
	@$(MAKE) --no-print-directory summary

# Internal: run one step, capture status + log, continue on failure.
.PHONY: _run
_run:
	@mkdir -p $(LOG_DIR)
	@log=$(LOG_DIR)/$$(echo '$(STEP)' | tr '/' '_').log; \
	printf '%b==>%b %s\n' '\033[1;36m' '\033[0m' '$(STEP)'; \
	if $(CMD) > "$$log" 2>&1; then \
		printf '%b    OK%b   (log: %s)\n' '\033[1;32m' '\033[0m' "$$log"; \
		echo '$(STEP)' >> $(STATUS_DIR)/passed; \
	else \
		rc=$$?; \
		printf '%b    FAIL%b (rc=%d, log: %s)\n' '\033[1;31m' '\033[0m' "$$rc" "$$log"; \
		echo '$(STEP)' >> $(STATUS_DIR)/failed; \
		tail -n 12 "$$log" | sed 's/^/      | /'; \
	fi

summary:
	@echo
	@echo '================================================================'
	@echo 'Build summary'
	@echo '================================================================'
	@passed=$$(wc -l < $(STATUS_DIR)/passed 2>/dev/null || echo 0); \
	failed=$$(wc -l < $(STATUS_DIR)/failed 2>/dev/null || echo 0); \
	printf 'Passed: %s\n' "$$passed"; \
	if [ -s $(STATUS_DIR)/passed ]; then \
		while IFS= read -r m; do printf '  %b[OK]%b   %s\n' '\033[1;32m' '\033[0m' "$$m"; done < $(STATUS_DIR)/passed; \
	fi; \
	printf 'Failed: %s\n' "$$failed"; \
	if [ -s $(STATUS_DIR)/failed ]; then \
		while IFS= read -r m; do printf '  %b[FAIL]%b %s\n' '\033[1;31m' '\033[0m' "$$m"; done < $(STATUS_DIR)/failed; \
		echo; \
		echo 'See logs in $(LOG_DIR)/'; \
		exit 1; \
	fi

# Individual module targets (handy for incremental builds).
TerminalFramework:
	$(PASBUILD) compile -f $(PROJECT_XML) -m TerminalFramework -p $(PROFILE)

ViewfpGUI:
	$(PASBUILD) compile -f $(PROJECT_XML) -m ViewfpGUI -p $(PROFILE)

ViewLCL:
	$(PASBUILD) compile -f $(PROJECT_XML) -m ViewLCL -p $(PROFILE)

ExampleTerminal:
	$(PASBUILD) compile -f $(PROJECT_XML) -m ExampleTerminal -p $(PROFILE)

ExampleTerminalLCL:
	$(PASBUILD) compile -f $(PROJECT_XML) -m ExampleTerminalLCL -p $(PROFILE)

replay Replay:
	$(PASBUILD) compile -f $(PROJECT_XML) -m Replay -p $(PROFILE)

lcl-lazbuild:
	./ExampleTerminalLCL/build.sh

LibTermView:
	./LibTermView/build.sh

ViewGtk4: LibTermView
	./ViewGtk4/build.sh

ExampleTerminalGtk4: ViewGtk4
	./ExampleTerminalGtk4/build.sh

gtk4: ExampleTerminalGtk4

release:
	./tools/release.sh

clean:
	@for d in TerminalFramework ViewfpGUI ViewLCL ExampleTerminal ExampleTerminalLCL tools/replay; do \
		rm -rf $$d/target/units $$d/target/pasbuild-status $$d/target/bootstrap_program* 2>/dev/null; \
	done
	rm -rf $(STATUS_DIR)
	@echo 'Cleaned.'

help:
	@echo 'Targets:'
	@echo '  make                     build everything, summary at end'
	@echo '  make <ModuleName>        build one module via pasbuild'
	@echo '  make lcl-lazbuild        build ExampleTerminalLCL via lazbuild'
	@echo '  make clean               wipe target/ dirs'
	@echo
	@echo 'Variables:'
	@echo '  PROFILE=debug|release    pasbuild profile (default: debug)'
	@echo '  PASBUILD=<path>          override pasbuild binary'
	@echo '  LAZBUILD=<path>          override lazbuild binary'
