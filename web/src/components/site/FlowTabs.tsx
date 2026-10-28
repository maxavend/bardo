import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"

interface Stage {
  value: string
  label: string
  caption: string
  alt: string
  slotAlt: string
  desktop: { src: string; width: number; height: number }
  mobile: { src: string; width: number; height: number }
}

interface FlowTabsProps {
  stages: Stage[]
}

export function FlowTabs({ stages }: FlowTabsProps) {
  return (
    <Tabs defaultValue={stages[0].value} className="gap-10">
      <TabsList aria-label="Etapas de una reunión" className="max-sm:flex max-sm:w-full max-sm:overflow-x-auto">
        {stages.map((stage) => (
          <TabsTrigger key={stage.value} value={stage.value} className="max-sm:px-4">
            {stage.label}
          </TabsTrigger>
        ))}
      </TabsList>
      {stages.map((stage) => (
        <TabsContent key={stage.value} value={stage.value} keepMounted>
          <figure className="m-0 flex flex-col gap-4">
            <div
              className="relative m-0 aspect-[2400/938] overflow-hidden rounded-window bg-paper-2 max-sm:-mr-(--gutter) max-sm:aspect-[900/696] max-sm:rounded-r-none"
              data-slot={stage.value}
              data-kind="product"
              data-alt={stage.slotAlt}
            >
              <picture className="absolute inset-0 z-1">
                <source
                  media="(max-width: 40rem)"
                  srcSet={stage.mobile.src}
                  width={stage.mobile.width}
                  height={stage.mobile.height}
                />
                <img
                  className="size-full object-cover object-top outline-1 -outline-offset-1 outline-ink/8"
                  src={stage.desktop.src}
                  width={stage.desktop.width}
                  height={stage.desktop.height}
                  alt={stage.alt}
                  loading="lazy"
                />
              </picture>
            </div>
            <figcaption className="text-sm text-ink-muted">{stage.caption}</figcaption>
          </figure>
        </TabsContent>
      ))}
    </Tabs>
  )
}
