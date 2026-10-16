/* =============================================================================
   CRM 9.1 On-Premise - BulkOperationLog N:N ilişki grubu düzeltmesi
   -----------------------------------------------------------------------------
   Belirti : Form düzenleyicide subgrid eklerken
             "There is no Relationship with referencing attribute id
              e305e856-... involved in the EntityRelationship with id ..."
   Neden   : msdynce_MarketingPatch, BulkOperation_* ve CampaignActivity_* N:N
             gruplarına "Source..." (regardingobjectid) yerine
             "Created..." (createdobjectid) ilişkisini bağlıyor.
   Çözüm   : Her bozuk gruptaki Created... üyeliğini aynı varlığın Source...
             ilişkisiyle değiştirir. ID'ler her organizasyonda farklı olduğu
             için hepsini kendisi bulur.

   KULLANIM
     1) <Org>_MSCRM veritabanının tam yedeğini alın.
     2) @Apply = 0 ile çalıştırın  -> sadece önizleme, hiçbir şey değişmez.
     3) Önizleme doğruysa @Apply = 1 yapıp tekrar çalıştırın.
     4) Tüm CRM sunucularında iisreset + Async / Async Maintenance /
        Sandbox servislerini yeniden başlatın.
   Script tekrar çalıştırılabilir: bozuk satır yoksa hiçbir şey yapmaz.
   UYARI: Metadata tablolarının doğrudan değiştirilmesi Microsoft tarafından
          desteklenmez. Yedeksiz çalıştırmayın.
   ============================================================================= */

DECLARE @Apply bit = 0;   -- 0 = önizleme, 1 = uygula

SET XACT_ABORT ON;
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;   -- 10 sn'den uzun kilit beklerse hata verir, otomatik geri alır

DECLARE @blog uniqueidentifier, @regarding uniqueidentifier, @created uniqueidentifier;

SELECT @blog = EntityId
FROM MetadataSchema.Entity WITH (NOLOCK)
WHERE Name = 'BulkOperationLog' AND OverwriteTime = '1900-01-01';

SELECT @regarding = AttributeId
FROM MetadataSchema.Attribute WITH (NOLOCK)
WHERE EntityId = @blog AND Name = 'regardingobjectid' AND OverwriteTime = '1900-01-01';

SELECT @created = AttributeId
FROM MetadataSchema.Attribute WITH (NOLOCK)
WHERE EntityId = @blog AND Name = 'createdobjectid' AND OverwriteTime = '1900-01-01';

IF @blog IS NULL OR @regarding IS NULL OR @created IS NULL
BEGIN
    RAISERROR('BulkOperationLog varlığı veya alanları bulunamadı; durduruldu.', 16, 1);
    RETURN;
END

-- Bozuk satırlar: N:N grubunda createdobjectid kullanan BulkOperationLog ilişkisi
DECLARE @fix TABLE (
    GroupName  nvarchar(256),
    GroupId    uniqueidentifier,
    RowId      uniqueidentifier,
    WrongName  nvarchar(256),
    WrongId    uniqueidentifier,
    RightName  nvarchar(256),
    RightId    uniqueidentifier,
    RightCount int
);

INSERT @fix
SELECT er.SchemaName, er.EntityRelationshipId, err.EntityRelationshipRelationshipsId,
       wr.Name, wr.RelationshipId, rr.Name, rr.RelationshipId, rr.Cnt
FROM MetadataSchema.EntityRelationship er WITH (NOLOCK)
JOIN MetadataSchema.EntityRelationshipRelationships err WITH (NOLOCK)
     ON err.EntityRelationshipId = er.EntityRelationshipId AND err.OverwriteTime = '1900-01-01'
JOIN MetadataSchema.Relationship wr WITH (NOLOCK)
     ON wr.RelationshipId = err.RelationshipId AND wr.OverwriteTime = '1900-01-01'
    AND wr.ReferencingEntityId = @blog AND wr.ReferencingAttributeId = @created
OUTER APPLY (
    SELECT TOP 1 r.Name, r.RelationshipId, COUNT(*) OVER () AS Cnt
    FROM MetadataSchema.Relationship r WITH (NOLOCK)
    WHERE r.OverwriteTime = '1900-01-01'
      AND r.ReferencingEntityId = @blog
      AND r.ReferencingAttributeId = @regarding
      AND r.ReferencedEntityId = wr.ReferencedEntityId
) rr
WHERE er.OverwriteTime = '1900-01-01'
  AND er.EntityRelationshipType = 1;   -- N:N

-- Önizleme
SELECT GroupName, RowId, WrongName, WrongId, RightName, RightId FROM @fix ORDER BY GroupName;

DECLARE @n int = (SELECT COUNT(*) FROM @fix);

IF @n = 0
BEGIN
    PRINT 'Bozuk satır yok; değişiklik gerekmiyor.';
    RETURN;
END

-- Güvenlik kontrolleri
IF EXISTS (SELECT 1 FROM @fix WHERE RightId IS NULL OR RightCount <> 1)
BEGIN
    RAISERROR('Bazı gruplar için tek ve kesin bir Source (regardingobjectid) ilişkisi bulunamadı; durduruldu.', 16, 1);
    RETURN;
END

IF EXISTS (SELECT 1 FROM @fix f
           JOIN MetadataSchema.EntityRelationshipRelationships x WITH (NOLOCK)
             ON x.EntityRelationshipId = f.GroupId AND x.RelationshipId = f.RightId
            AND x.OverwriteTime = '1900-01-01')
BEGIN
    RAISERROR('Doğru ilişki zaten grupta (mükerrer olur); durduruldu.', 16, 1);
    RETURN;
END

IF EXISTS (SELECT GroupId FROM @fix GROUP BY GroupId HAVING COUNT(*) > 1)
BEGIN
    RAISERROR('Aynı grupta birden fazla bozuk satır var; durduruldu.', 16, 1);
    RETURN;
END

IF @Apply = 0
BEGIN
    PRINT CONCAT('ÖNİZLEME: ', @n, ' satır düzeltilecek. Uygulamak için @Apply = 1 yapın.');
    RETURN;
END

-- Uygula
BEGIN TRAN;

UPDATE err
SET RelationshipId = f.RightId
FROM MetadataSchema.EntityRelationshipRelationships err
JOIN @fix f
  ON err.EntityRelationshipRelationshipsId = f.RowId
 AND err.RelationshipId = f.WrongId
WHERE err.OverwriteTime = '1900-01-01';

DECLARE @updated int = @@ROWCOUNT;

-- Kontrol: hiçbir N:N grubunda createdobjectid kullanan BulkOperationLog ilişkisi kalmamalı
DECLARE @remaining int = (
    SELECT COUNT(*)
    FROM MetadataSchema.EntityRelationship er WITH (NOLOCK)
    JOIN MetadataSchema.EntityRelationshipRelationships err
         ON err.EntityRelationshipId = er.EntityRelationshipId AND err.OverwriteTime = '1900-01-01'
    JOIN MetadataSchema.Relationship r WITH (NOLOCK)
         ON r.RelationshipId = err.RelationshipId AND r.OverwriteTime = '1900-01-01'
    WHERE er.OverwriteTime = '1900-01-01'
      AND er.EntityRelationshipType = 1
      AND r.ReferencingEntityId = @blog
      AND r.ReferencingAttributeId = @created);

IF @updated = @n AND @remaining = 0
BEGIN
    COMMIT;
    PRINT CONCAT('TAMAM: ', @updated, ' satır güncellendi ve kaydedildi. Şimdi iisreset + Async servislerini yeniden başlatın.');
END
ELSE
BEGIN
    ROLLBACK;
    PRINT CONCAT('GERİ ALINDI: güncellenen=', @updated, ', beklenen=', @n, ', kalan bozuk=', @remaining);
END

-- Son durum
SELECT er.SchemaName, r.Name AS Relationship, a.Name AS ReferencingAttribute
FROM MetadataSchema.EntityRelationship er WITH (NOLOCK)
JOIN MetadataSchema.EntityRelationshipRelationships err WITH (NOLOCK)
     ON err.EntityRelationshipId = er.EntityRelationshipId AND err.OverwriteTime = '1900-01-01'
JOIN MetadataSchema.Relationship r WITH (NOLOCK)
     ON r.RelationshipId = err.RelationshipId AND r.OverwriteTime = '1900-01-01'
JOIN MetadataSchema.Attribute a WITH (NOLOCK)
     ON a.AttributeId = r.ReferencingAttributeId AND a.OverwriteTime = '1900-01-01'
WHERE er.OverwriteTime = '1900-01-01'
  AND er.EntityRelationshipType = 1
  AND er.EntityRelationshipId IN (SELECT GroupId FROM @fix)
ORDER BY er.SchemaName, a.Name;
