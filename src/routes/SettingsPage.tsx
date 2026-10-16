import { Monitor, Moon, Sun } from 'lucide-react'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { useTheme } from '@/theme/ThemeProvider'
import type { ThemePreference } from '@/theme/theme'

const THEME_OPTIONS: { value: ThemePreference; label: string; icon: typeof Sun }[] = [
  { value: 'light', label: 'Light', icon: Sun },
  { value: 'dark', label: 'Dark', icon: Moon },
  { value: 'system', label: 'System', icon: Monitor },
]

function isThemePreference(value: string): value is ThemePreference {
  return THEME_OPTIONS.some((option) => option.value === value)
}

export function SettingsPage() {
  const { preference, resolved, setPreference } = useTheme()

  return (
    <div className="flex max-w-2xl flex-col gap-4">
      <h1 className="text-lg font-semibold">Settings</h1>
      <Card>
        <CardHeader>
          <CardTitle>Appearance</CardTitle>
          <CardDescription>
            System follows your device and switches the moment macOS does.
            {preference === 'system' && ` Currently ${resolved}.`}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ToggleGroup
            type="single"
            variant="outline"
            spacing={0}
            value={preference}
            onValueChange={(value) => {
              // Radix sends "" when the active item is clicked again; keep the current choice.
              if (isThemePreference(value)) setPreference(value)
            }}
            aria-label="Theme"
          >
            {THEME_OPTIONS.map(({ value, label, icon: Icon }) => (
              <ToggleGroupItem key={value} value={value} className="px-3">
                <Icon />
                {label}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </CardContent>
      </Card>
    </div>
  )
}
