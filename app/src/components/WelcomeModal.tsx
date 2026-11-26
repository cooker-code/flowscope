import { useState, useEffect } from 'react';
import { Database, GitBranch, Shield, Keyboard } from 'lucide-react';

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { STORAGE_KEYS } from '@/lib/constants';
import { useBackend } from '@/lib/backend-context';

interface WelcomeModalProps {
  onClose?: () => void;
}

export function WelcomeModal({ onClose }: WelcomeModalProps) {
  const { backendType } = useBackend();
  const serverMode = backendType === 'rest';
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const hasSeenWelcome = localStorage.getItem(STORAGE_KEYS.WELCOME_SHOWN) === 'true';
    if (!hasSeenWelcome) {
      setOpen(true);
    }
  }, []);

  const handleClose = () => {
    localStorage.setItem(STORAGE_KEYS.WELCOME_SHOWN, 'true');
    setOpen(false);
    onClose?.();
  };

  return (
    <Dialog open={open} onOpenChange={(isOpen) => !isOpen && handleClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="text-xl">Welcome to FlowScope</DialogTitle>
          <DialogDescription>
            {serverMode
              ? 'SQL lineage analysis through your FlowScope server.'
              : 'A privacy-first SQL lineage engine that runs entirely in your browser.'}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-4">
          <div className="flex items-start gap-3">
            <Database className="h-5 w-5 text-muted-foreground mt-0.5 shrink-0" />
            <div>
              <p className="font-medium text-sm">SQL Lineage Analysis</p>
              <p className="text-sm text-muted-foreground">
                Visualize how data flows through your queries across tables, CTEs, and columns.
              </p>
            </div>
          </div>

          <div className="flex items-start gap-3">
            <GitBranch className="h-5 w-5 text-muted-foreground mt-0.5 shrink-0" />
            <div>
              <p className="font-medium text-sm">Multi-File Projects</p>
              <p className="text-sm text-muted-foreground">
                Organize your SQL files into projects and analyze dependencies across files.
              </p>
            </div>
          </div>

          <div className="flex items-start gap-3">
            <Shield className="h-5 w-5 text-muted-foreground mt-0.5 shrink-0" />
            <div>
              <p className="font-medium text-sm">
                {serverMode ? 'Caller Policies' : 'Privacy First'}
              </p>
              <p className="text-sm text-muted-foreground">
                {serverMode
                  ? 'Your server policy controls whether analysis only parses, updates formal lineage, or records personal query usage.'
                  : 'All analysis runs locally in your browser. Your SQL never leaves your machine.'}
              </p>
            </div>
          </div>

          <div className="flex items-start gap-3">
            <Keyboard className="h-5 w-5 text-muted-foreground mt-0.5 shrink-0" />
            <div>
              <p className="font-medium text-sm">Keyboard Driven</p>
              <p className="text-sm text-muted-foreground">
                <kbd className="px-1.5 py-0.5 text-xs bg-muted rounded border">⌘P</kbd> projects,{' '}
                <kbd className="px-1.5 py-0.5 text-xs bg-muted rounded border">⌘O</kbd> files,{' '}
                <kbd className="px-1.5 py-0.5 text-xs bg-muted rounded border">⌘Enter</kbd> analyze
              </p>
            </div>
          </div>
        </div>

        <DialogFooter>
          <Button onClick={handleClose}>Get Started</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
