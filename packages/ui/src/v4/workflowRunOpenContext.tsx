import { createContext, useContext, useMemo, useRef, type ReactNode } from "react";
import type { SessionWorkflowRunSummary } from "@ccbuddy/shared/ccbuddy-protocol-v4";

export interface WorkflowRunOpenTarget {
  workspacePath: string;
  workspaceIdentity?: string;
  sessionId: string;
  run: SessionWorkflowRunSummary;
}

type WorkflowRunOpenHandler = (target: WorkflowRunOpenTarget) => void;

const WorkflowRunOpenContext = createContext<WorkflowRunOpenHandler | null>(null);

export function WorkflowRunOpenProvider({
  onOpenRun,
  children,
}: {
  onOpenRun: WorkflowRunOpenHandler;
  children: ReactNode;
}) {
  const handlerRef = useRef(onOpenRun);
  handlerRef.current = onOpenRun;
  const stable = useMemo<WorkflowRunOpenHandler>(() => (target) => handlerRef.current(target), []);
  return (
    <WorkflowRunOpenContext.Provider value={stable}>{children}</WorkflowRunOpenContext.Provider>
  );
}

export function useWorkflowRunOpen(): WorkflowRunOpenHandler | null {
  return useContext(WorkflowRunOpenContext);
}
